%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @copyright 2011-2012 Opscode Inc.

-module(pushysim_client).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,
         heartbeat/0
        ]).

%% ------------------------------------------------------------------
%% Private Exports - only exported for instrumentation
%% ------------------------------------------------------------------

-export([send_heartbeat/1,
         send_response/3
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq/include/erlzmq.hrl").
-include("pushysim.hrl").


%% TODO: tighten typedefs up
-record(state,
        {command_sock :: any(),
         client_name :: binary(),
         heartbeat_interval :: integer(),
         sequence :: integer(),
         server_public_key :: binary(),
         private_key :: any(),
         incarnation_id :: binary(),
         node_id :: binary()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(ClientState) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [ClientState], []).

heartbeat() ->
    gen_server:cast(?SERVER, heartbeat).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init([#client_state{}]) -> {ok, #state{} }.
init([#client_state{ctx = Ctx,
                    client_name = ClientName,
                    server_name = Hostname,
                    server_port = Port,
                    node_id = NodeId,
                    instance_id = InstanceId}]) ->
    IncarnationId = list_to_binary(pushy_util:guid_v4()),

    lager:info("Getting config from Pushy Server ~s:~w", [Hostname, Port]),
    Config = pushy_client_config:get_config(?PUSHY_ORGNAME, Hostname, Port),

    CommandAddress = proplists:get_value(command_address, Config),

    NodeInstance = list_to_binary(io_lib:format("~s~4..0B", [NodeId, InstanceId])),
    lager:info("Starting pushy client with node id ~s (~s).", [NodeInstance, IncarnationId]),
    Interval =  pushy_util:get_env(pushysim, heartbeat_interval, fun is_integer/1),

    lager:info("Client : Connecting to command channel at ~s.", [CommandAddress]),
    {ok, Sock} = erlzmq:socket(Ctx, [dealer, {active, true}]),
    erlzmq:setsockopt(Sock, linger, 0),
    erlzmq:connect(Sock, CommandAddress),

    {ok, PrivateKey} = chef_keyring:get_key(client_private),
    {ok, PublicKey} = server_public_key(Config),

    State = #state{command_sock = Sock,
                   client_name = ClientName,
                   heartbeat_interval = Interval,
                   sequence = 0,
                   server_public_key = PublicKey,
                   private_key = PrivateKey,
                   node_id = NodeInstance,
                   incarnation_id = IncarnationId
                  },
    timer:apply_interval(Interval, ?MODULE, heartbeat, []),
    {ok, State}.

handle_call(_Request, _From, State) ->
    {noreply, ok, State}.

handle_cast(heartbeat, State) ->
    State1 = send_heartbeat(State),
    {noreply, State1};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({zmq, Sock, Frame, [rcvmore]}, State) ->
    {noreply, do_receive(Sock, Frame, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

server_public_key(Config) ->
    RawKey = proplists:get_value(public_key, Config),
    case chef_authn:extract_public_or_private_key(RawKey) of
        {error, bad_key} ->
            lager:error("Can't decode Public Key ~s~n", [RawKey]),
            {error, bad_key};
         Key when is_tuple(Key) ->
            {ok, Key}
    end.

-spec send_heartbeat(#state{}) -> #state{}.
send_heartbeat(#state{command_sock = Sock,
                      client_name = ClientName,
                      sequence = Sequence,
                      private_key = PrivateKey,
                      incarnation_id = IncarnationId,
                      node_id = NodeId} = State) ->

    Msg = {[{node, NodeId},
            {client, ClientName},
            {org, "pushy"},
            {type, heartbeat},
            {timestamp, list_to_binary(httpd_util:rfc1123_date())},
            {sequence, Sequence},
            {incarnation_id, IncarnationId},
            {job_state, "idle"},
            {job_id, "null"}
           ]},
    % JSON encode message
    BodyFrame = jiffy:encode(Msg),

    % Send Header (including signed checksum)
    HeaderFrame = pushy_util:signed_header_from_message(PrivateKey, BodyFrame),
    pushy_messaging:send_message(Sock, [HeaderFrame, BodyFrame]),
    lager:debug("Heartbeat sent: header=~s,body=~s",[HeaderFrame, BodyFrame]),
    State#state{sequence=Sequence + 1}.

send_response(Type, JobId, #state{command_sock = Sock,
                                  client_name = ClientName,
                                  private_key = PrivateKey,
                                  incarnation_id = IncarnationId,
                                  node_id = NodeId}) ->
    Msg = {[{node, NodeId},
            {client, ClientName},
            {org, "pushy"},
            {type, Type},
            {timestamp, list_to_binary(httpd_util:rfc1123_date())},
            {incarnation_id, IncarnationId},
            {job_id, JobId}
           ]},
    % JSON encode message
    BodyFrame = jiffy:encode(Msg),

    % Send Header (including signed checksum)
    HeaderFrame = pushy_util:signed_header_from_message(PrivateKey, BodyFrame),
    pushy_messaging:send_message(Sock, [HeaderFrame, BodyFrame]),
    lager:debug("Response sent: header=~s,body=~s",[HeaderFrame, BodyFrame]).


do_receive(Sock, Frame, #state{server_public_key = PublicKey} = State) ->
    [Header, Body] = pushy_messaging:receive_message_async(Sock, Frame),

    lager:debug("Received message~n\tA ~p~n\tH ~s~n\tB ~s", [Header, Body]),
    case catch pushy_util:do_authenticate_message(Header, Body, PublicKey) of
        ok ->
            process_message(State, Header, Body);
        {no_authn, bad_sig} ->
            lager:error("Command message failed verification: header=~s", [Header]),
            State
    end.

process_message(State, _Header, Body) ->
    case catch jiffy:decode(Body) of
        {Data} ->
            Type = ej:get({<<"type">>}, Data),
            JobId = ej:get({<<"job_id">>}, Data),
            respond(Type, JobId, State),
            State;
        {'EXIT', Error} ->
            lager:error("Status message JSON parsing failed: body=~s, error=~s", [Body, Error]),
            State
    end.

respond(<<"commit">>, JobId, State) ->
    send_response(<<"ack_commit">>, JobId, State);
respond(<<"run">>, JobId, State) ->
    send_response(<<"ack_run">>, JobId, #state{node_id = NodeId} = State),
    lager:info("[~s] Wheee ! Running a job...", [NodeId]),
    send_response(<<"complete">>, JobId, State);
respond(<<"abort">>, JobId, State) ->
    send_response(<<"aborted">>, JobId, State).

