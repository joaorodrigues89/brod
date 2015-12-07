%%%
%%%   Copyright (c) 2015 Klarna AB
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%

%%%=============================================================================
%%% @doc
%%% @copyright 2015 Klarna AB
%%% @end
%%%=============================================================================

-module(brod_client).
-behaviour(gen_server).

%% TODO: perhaps add a connect_leader/3 API?
-export([ connect_broker/3
        , get_metadata/2
        , start_link/2
        ]).

-export([ code_change/3
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , init/1
        , terminate/2
        ]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("brod_int.hrl").

-type endpoint() :: {hostname(), portnum()}.

-define(DEFAULT_RECONNECT_COOL_DOWN_SECONDS, 1).

-define(dead_since(TS, REASON), {dead_since, TS, REASON}).
-type dead_socket() :: ?dead_since(erlang:timestamp(), any()).

-record(sock,
        { endpoint :: endpoint()
        , sock_pid :: pid() | dead_socket()
        }).

-record(state,
        { client_id    :: client_id()
        , endpoints    :: [endpoint()]
        , meta_sock    :: pid()
        , sockets = [] :: [#sock{}]
        }).

%%%_* APIs ---------------------------------------------------------------------

start_link(ClientId, Args) when is_atom(ClientId) ->
  gen_server:start_link({local, ClientId}, ?MODULE, {ClientId, Args}, []).

-spec get_metadata(client_id(), topic()) -> {ok, #metadata_response{}}.
get_metadata(ClientId, Topic) ->
  gen_server:call(ClientId, {get_metadata, Topic}, infinity).

%% @doc Establish a (maybe new) connection to kafka broker at Host:Port.
%% In case there is alreay a connection established, it is re-used.
%% @end
-spec connect_broker(client_id(), hostname(), portnum()) ->
        {ok, pid()} | {error, any()}.
connect_broker(ClientId, Host, Port) ->
  gen_server:call(ClientId, {connect, Host, Port}, infinity).

%%%_* gen_server callbacks -----------------------------------------------------

init({ClientId, Args}) ->
  erlang:process_flag(trap_exit, true),
  Endpoints = proplists:get_value(endpoints, Args),
  true = is_list(Endpoints) andalso length(Endpoints) > 0, %% assert
  {ok, #state{ client_id = ClientId
             , endpoints = Endpoints
             , meta_sock = start_metadata_socket(Endpoints)
             }}.

handle_call({get_metadata, Topic}, _From, #state{meta_sock = Sock} = State) ->
  Request = #metadata_request{topics = [Topic]},
  %% TODO: timeout configurable
  Respons = brod_sock:send_sync(Sock, Request, 10000),
  {reply, Respons, State};
handle_call({connect, Host, Port}, _From, State) ->
  {NewState, Result} = do_connect(State, Host, Port),
  {reply, Result, NewState};
handle_call(Call, _From, State) ->
  {reply, {error, {unknown_call, Call}}, State}.

handle_cast(_Cast, State) ->
  {noreply, State}.

%% TODO: maybe add a timer to clean up very old ?dead_since sockets
handle_info({'EXIT', Pid, _Reason}, #state{ meta_sock = Pid
                                          , endpoints = Endpoints
                                          } = State) ->
  NewPid = start_metadata_socket(Endpoints),
  {nereply, State#state{meta_sock = NewPid}};
handle_info({'EXIT', Pid, Reason}, State) ->
  {ok, NewState} = handle_socket_down(State, Pid, Reason),
  {noreply, NewState};
handle_info(_Info, State) ->
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

terminate(_Reason, #state{sockets = Sockets}) ->
  lists:foreach(
    fun(#sock{sock_pid = Pid}) ->
      case brod_utils:is_pid_alive(Pid) of
        true  -> exit(Pid, shutdown);
        false -> ok
      end
    end, Sockets).

%%%_* Internal functions -------------------------------------------------------

-spec do_connect(#state{}, hostname(), portnum()) ->
        {#state{}, Result} when Result :: {ok, pid()} | {error, any()}.
do_connect(#state{} = State, Host, Port) ->
  case find_socket(State, Host, Port) of
    {ok, Pid} ->
      {State, {ok, Pid}};
    {error, Reason} ->
      maybe_reconnect(State, Host, Port, Reason)
  end.

-spec maybe_reconnect(#state{}, hostname(), portnum(), Reason) ->
        {#state{}, Result} when
          Reason :: not_found | dead_socket(),
          Result :: {ok, pid()} | {error, any()}.
maybe_reconnect(State, Host, Port, not_found) ->
  %% connect for the first time
  reconnect(State, Host, Port);
maybe_reconnect(State, Host, Port, ?dead_since(Ts, Reason)) ->
  case is_cooled_down(Ts, Reason) of
    true  -> reconnect(State, Host, Port);
    false -> {State, {error, Reason}}
  end.

-spec reconnect(#state{}, hostname(), portnum()) -> {#state{}, Result}
        when Result :: {ok, pid()} | {error, any()}.
reconnect(#state{ client_id = ClientId
                , sockets = Sockets
                } = State, Host, Port) ->
  case brod_sock:start_link(self(), Host, Port, ClientId, []) of
    {ok, Pid} ->
      S = #sock{ endpoint = {Host, Port}
               , sock_pid = Pid
               },
      NewSockets = lists:keystore({Host, Port}, #sock.endpoint, Sockets, S),
      {State#state{sockets = NewSockets}, {ok, Pid}};
    {error, Reason} ->
      {ok, NewState} = mark_socket_dead(State, {Host, Port}, Reason),
      {NewState, {error, Reason}}
  end.

%% @private Handle socket pid EXIT event, keep the timestamp.
%% But do not restart yet. Connection will be re-established when the partition
%% worker requests so.
%% @end
-spec handle_socket_down(#state{}, pid(), any()) -> {ok, #state{}}.
handle_socket_down(#state{sockets = Sockets} = State, Pid, Reason) ->
  case lists:keyfind(Pid, #sock.sock_pid, Sockets) of
    #sock{endpoint = Endpoint} -> mark_socket_dead(State, Endpoint, Reason);
    false                      -> {ok, State}
  end.

-spec mark_socket_dead(#state{}, endpoint(), any()) -> {ok, #state{}}.
mark_socket_dead(#state{sockets = Sockets} = State, Endpoint, Reason) ->
  Conn = #sock{ endpoint = Endpoint
              , sock_pid = ?dead_since(os:timestamp(), Reason)
              },
  NewSockets = lists:keystore(Endpoint, #sock.endpoint, Sockets, Conn),
  {ok, State#state{sockets = NewSockets}}.

-spec find_socket(#state{}, hostname(), portnum()) ->
        {ok, pid()} %% normal case
      | {error, not_found} %% first call
      | {error, dead_socket()}.
find_socket(#state{sockets = Sockets}, Host, Port) ->
  case lists:keyfind({Host, Port}, #sock.endpoint, Sockets) of
    #sock{sock_pid = Pid} when is_pid(Pid)         -> {ok, Pid};
    #sock{sock_pid = ?dead_since(_, _) = NotAlive} -> {error, NotAlive};
    false                                          -> {error, not_found}
  end.

%% @private Check if the socket is down for long enough to retry.
is_cooled_down(Ts, _Reason) ->
  %% TODO make it a per-client config
  Threshold = application:get_env(brod, reconnect_cool_down_seconds,
                                  ?DEFAULT_RECONNECT_COOL_DOWN_SECONDS),
  Now = os:timestamp(),
  case timer:now_diff(Now, Ts) div 1000000 of
    Diff when Diff > Threshold -> true;
    _                          -> false
  end.

%% @doc Establish a dedicated socket to kafka cluster endpoint(s) for
%% metadata retrievals.
%% NOTE: This socket is not intended for kafka payload, the endpoint
%%       Host:Port can be any of the brokers in the cluster which does not
%%       necessarily have to be the leader of any partition, or it might
%%       be a load-balanced entrypoint to the remote kakfa cluster.
%% NOTE: crash in case failed to connect to any of the endpoints.
%%       should be restarted by supervisor
%% @end
-spec start_metadata_socket([endpoint()]) -> pid() | no_return().
start_metadata_socket(Endpoints) ->
  case brod_utils:try_connect(Endpoints) of
    {ok, Pid}       -> Pid;
    {error, Reason} -> erlang:error({"metadata socket failure", Reason})
  end.

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
