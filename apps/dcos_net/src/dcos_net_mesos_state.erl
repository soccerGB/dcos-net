-module(dcos_net_mesos_state).

%% API
-export([
    start_link/0,
    subscribe/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-export_type([task_id/0, task/0, task_state/0, task_port/0]).

-type task_id() :: binary().
-type task() :: #{
    name => binary(),
    framework => binary() | {id, binary()},
    agent_ip => inet:ip4_address() | {id, binary()},
    container_ip => [inet:ip_address()],
    state => task_state(),
    ports => [task_port()]
}.
-type task_state() :: true | running | {running, boolean()} | false.
-type task_port() :: #{
    name => binary(),
    host_port => inet:port_number(),
    port => inet:port_number(),
    protocol => tcp | udp,
    vip => [binary()] | {host, [binary()]}
}.

-record(state, {
    pid :: pid(),
    ref :: reference(),
    size = undefined :: pos_integer() | undefined,
    buf = <<>> :: binary(),
    timeout = 15000 :: timeout(),
    timeout_ref = make_ref() :: reference(),
    agents = #{} :: #{binary() => inet:ip4_address()},
    frameworks = #{} :: #{binary() => binary()},
    tasks = #{} :: #{task_id() => task()},
    waiting_tasks = #{} :: #{task_id() => true},
    subs = undefined :: #{pid() => reference()} | undefined
}).

-type state() :: #state{}.

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec(subscribe() -> {ok, MonRef, Tasks} | {error, atom()}
    when MonRef :: reference(), Tasks :: #{task_id() => task()}).
subscribe() ->
    case whereis(?MODULE) of
        undefined ->
            {error, not_found};
        Pid ->
            subscribe(Pid)
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! init,
    {ok, []}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, []) ->
    case handle_init() of
        {ok, State} ->
            {noreply, State};
        {error, redirect} ->
            % It's not a leader, don't log annything
            timer:sleep(100),
            self() ! init,
            {noreply, []};
        {error, Error} ->
            lager:error("Couldn't connect to mesos: ~p", [Error]),
            timer:sleep(100),
            self() ! init,
            {noreply, []}
    end;
handle_info({subscribe, Pid, Ref}, State) ->
    {noreply, handle_subscribe(Pid, Ref, State)};
handle_info({http, {Ref, stream, Data}}, #state{ref=Ref}=State) ->
    case stream(Data, State) of
        {next, State0} ->
            {noreply, State0};
        {next, Obj, State0} ->
            State1 = handle(Obj, State0),
            handle_info({http, {Ref, stream, <<>>}}, State1);
        {error, Error} ->
            lager:error("Mesos protocol error: ~p", [Error]),
            {stop, Error, State}
    end;
handle_info({timeout, TRef, httpc}, #state{ref=Ref, timeout_ref=TRef}=State) ->
    ok = httpc:cancel_request(Ref),
    lager:error("Mesos timeout"),
    {stop, {httpc, timeout}, State};
handle_info({http, {Ref, {error, Error}}}, #state{ref=Ref}=State) ->
    lager:error("Mesos connection terminated: ~p", [Error]),
    {stop, Error, State};
handle_info({'DOWN', _MonRef, process, Pid, Info}, #state{pid=Pid}=State) ->
    lager:error("Mesos http client: ~p", [Info]),
    {stop, Info, State};
handle_info({'DOWN', _MonRef, process, Pid, _Info}, #state{subs=Subs}=State) ->
    {noreply, State#state{subs=maps:remove(Pid, Subs)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Handle functions
%%%===================================================================

-spec(handle(jiffy:object(), state()) -> state()).
handle(#{<<"type">> := <<"SUBSCRIBED">>} = Obj, State) ->
    Obj0 = mget(<<"subscribed">>, Obj),
    handle(subscribed, Obj0, State);
handle(#{<<"type">> := <<"HEARTBEAT">>}, State) ->
    handle(heartbeat, #{}, State);
handle(#{<<"type">> := <<"TASK_ADDED">>} = Obj, State) ->
    Obj0 = mget(<<"task_added">>, Obj),
    handle(task_added, Obj0, State);
handle(#{<<"type">> := <<"TASK_UPDATED">>} = Obj, State) ->
    Obj0 = mget(<<"task_updated">>, Obj),
    handle(task_updated, Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_ADDED">>} = Obj, State) ->
    Obj0 = mget(<<"framework_added">>, Obj),
    handle(framework_added, Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_UPDATED">>} = Obj, State) ->
    Obj0 = mget(<<"framework_updated">>, Obj),
    handle(framework_updated, Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_REMOVED">>} = Obj, State) ->
    Obj0 = mget(<<"framework_removed">>, Obj),
    handle(framework_removed, Obj0, State);
handle(#{<<"type">> := <<"AGENT_ADDED">>} = Obj, State) ->
    Obj0 = mget(<<"agent_added">>, Obj),
    handle(agent_added, Obj0, State);
handle(#{<<"type">> := <<"AGENT_REMOVED">>} = Obj, State) ->
    Obj0 = mget(<<"agent_removed">>, Obj),
    handle(agent_removed, Obj0, State);
handle(Obj, State) ->
    lager:error("Unexpected mesos message type: ~p", [Obj]),
    State.

-spec(handle(atom(), jiffy:object(), state()) -> state()).
handle(subscribed, Obj, State) ->
    Timeout = mget(<<"heartbeat_interval_seconds">>, Obj),
    Timeout0 = erlang:trunc(Timeout * 1000),
    State0 = State#state{timeout = Timeout0},

    MState = mget(<<"get_state">>, Obj, #{}),

    Agents = mget([<<"get_agents">>, <<"agents">>], MState, []),
    State1 =
        lists:foldl(fun (Agent, St) ->
            handle(agent_added, #{<<"agent">> => Agent}, St)
        end, State0, Agents),

    Frameworks = mget([<<"get_frameworks">>, <<"frameworks">>], MState, []),
    State2 =
        lists:foldl(fun (Framework, St) ->
            handle(framework_updated, #{<<"framework">> => Framework}, St)
        end, State1, Frameworks),

    Tasks = mget([<<"get_tasks">>, <<"tasks">>], MState, []),
    State3 =
        lists:foldl(fun (Task, St) ->
            handle_task(Task, St)
        end, State2, Tasks),

    State4 = State3#state{subs=#{}},

    erlang:garbage_collect(),
    handle(heartbeat, #{}, State4);

handle(heartbeat, _Obj, #state{timeout = T, timeout_ref = TRef}=State) ->
    TRef0 = erlang:start_timer(3 * T, self(), httpc),
    _ = erlang:cancel_timer(TRef),
    State#state{timeout_ref=TRef0};

handle(task_added, Obj, State) ->
    Task = mget(<<"task">>, Obj),
    handle_task(Task, State);

handle(task_updated, Obj, State) ->
    Task = mget(<<"status">>, Obj),
    FrameworkId = mget(<<"framework_id">>, Obj),
    Task0 = mput(<<"framework_id">>, FrameworkId, Task),
    handle_task(Task0, State);

handle(framework_added, Obj, State) ->
    handle(framework_updated, Obj, State);

handle(framework_updated, Obj, #state{frameworks=F}=State) ->
    Info = mget([<<"framework">>, <<"framework_info">>], Obj),
    Id = mget([<<"id">>, <<"value">>], Info),
    Name = mget(<<"name">>, Info, undefined),

    lager:notice("Framework ~s added, ~s", [Id, Name]),
    State0 = State#state{frameworks=mput(Id, Name, F)},
    handle_waiting_tasks(framework, Id, Name, State0);

handle(framework_removed, Obj, #state{frameworks=F}=State) ->
    Id = mget([<<"framework_info">>, <<"id">>, <<"value">>], Obj),
    lager:notice("Framework ~s removed", [Id]),
    State#state{frameworks=mremove(Id, F)};

handle(agent_added, Obj, #state{agents=A}=State) ->
    Info = mget([<<"agent">>, <<"agent_info">>], Obj),
    Id = mget([<<"id">>, <<"value">>], Info),
    {ok, Host} =
        try mget(<<"hostname">>, Info) of Hostname ->
            lager:notice("Agent ~s added, ~s", [Id, Hostname]),
            Hostname0 = binary_to_list(Hostname),
            inet:parse_ipv4strict_address(Hostname0)
        catch error:{badkey, _} ->
            lager:notice("Agent ~s added", [Id]),
            {ok, undefined}
        end,

    State0 = State#state{agents=mput(Id, Host, A)},
    handle_waiting_tasks(agent_ip, Id, Host, State0);

handle(agent_removed, Obj, #state{agents=A}=State) ->
    Id = mget([<<"agent_id">>, <<"value">>], Obj),
    lager:notice("Agent ~s removed", [Id]),
    State#state{agents=mremove(Id, A)}.

%%%===================================================================
%%% Handle task functions
%%%===================================================================

-spec(handle_task(jiffy:object(), state()) -> state()).
handle_task(TaskObj, #state{tasks=T}=State) ->
    TaskId = mget([<<"task_id">>, <<"value">>], TaskObj),
    Task = maps:get(TaskId, T, #{}),
    handle_task(TaskId, TaskObj, Task, State).

-spec(handle_task(
    task_id(), jiffy:object(),
    task(), state()) -> state()).
handle_task(TaskId, TaskObj, Task,
        #state{frameworks=F, agents=A}=State) ->
    AgentId = mget([<<"agent_id">>, <<"value">>], TaskObj),
    Agent = mget(AgentId, A, {id, AgentId}),

    FrameworkId = mget([<<"framework_id">>, <<"value">>], TaskObj),
    Framework = mget(FrameworkId, F, {id, FrameworkId}),

    Fields = #{
        name => {mget, <<"name">>},
        framework => {value, Framework},
        agent_ip => {value, Agent},
        container_ip => fun handle_task_ip/1,
        state => fun handle_task_state/1,
        ports => fun handle_task_ports/1
    },
    Task0 =
        maps:fold(
            fun (Key, {value, Value}, Acc) ->
                    mput(Key, Value, Acc);
                (Key, Fun, Acc) when is_function(Fun) ->
                    Value = Fun(TaskObj),
                    mput(Key, Value, Acc);
                (Key, {mget, Path}, Acc) ->
                    Value = mget(Path, TaskObj, undefined),
                    mput(Key, Value, Acc)
            end, Task, Fields),

    add_task(TaskId, Task, Task0, State).

-spec(add_task(task_id(), task(), task(), state()) -> state()).
add_task(TaskId, TaskPrev, TaskNew, State) ->
    case mdiff(TaskPrev, TaskNew) of
        MDiff when map_size(MDiff) =:= 0 ->
            State;
        MDiff ->
            lager:notice("Task ~s updated with ~p", [TaskId, MDiff]),
            add_task(TaskId, TaskNew, State)
    end.

-spec(add_task(task_id(), task(), state()) -> state()).
add_task(TaskId, #{state := false} = Task, #state{
        tasks=T, waiting_tasks=TW}=State) ->
    State0 = send_task(TaskId, Task, State),
    State0#state{
        tasks=mremove(TaskId, T),
        waiting_tasks=mremove(TaskId, TW)};
add_task(TaskId, Task, #state{tasks=T, waiting_tasks=TW}=State) ->
    % NOTE: you can get task info before you get agent or framework
    State0 = send_task(TaskId, Task, State),
    TW0 =
        case Task of
            #{agent_ip := {id, _Id}} ->
                mput(TaskId, true, TW);
            #{framework := {id, _Id}} ->
                mput(TaskId, true, TW);
            _Task ->
                mremove(TaskId, TW)
        end,
    State0#state{
        tasks=mput(TaskId, Task, T),
        waiting_tasks=TW0}.

-spec(handle_waiting_tasks(
    agent_ip | framework, binary(),
    term(), state()) -> state()).
handle_waiting_tasks(Key, Id, Value, #state{waiting_tasks=TW}=State) ->
    maps:fold(fun(TaskId, true, #state{tasks=T}=Acc) ->
        Task = maps:get(TaskId, T),
        case maps:get(Key, Task) of
            {id, Id} ->
                lager:notice("Task ~s updated with ~p", [TaskId, #{Key => Value}]),
                add_task(TaskId, mput(Key, Value, Task), Acc);
            _KValue ->
                Acc
        end
    end, State, TW).

%%%===================================================================
%%% Handle task fields
%%%===================================================================

% NOTE: See comments for enum TaskState (#L2170-L2230) in
% https://github.com/apache/mesos/blob/1.5.0/include/mesos/v1/mesos.proto
-define(IS_TERMINAL(S),
    S =:= <<"TASK_FINISHED">> orelse
    S =:= <<"TASK_FAILED">> orelse
    S =:= <<"TASK_KILLED">> orelse
    S =:= <<"TASK_ERROR">> orelse
    S =:= <<"TASK_DROPPED">> orelse
    S =:= <<"TASK_GONE">>
).

-spec(handle_task_state(jiffy:object()) -> task_state()).
handle_task_state(TaskObj) ->
    case maps:get(<<"state">>, TaskObj) of
        TaskState when ?IS_TERMINAL(TaskState) ->
            false;
        <<"TASK_RUNNING">> ->
            Status = handle_task_status(TaskObj),
            case mget(<<"healthy">>, Status, undefined) of
                undefined -> running;
                Healthy ->
                    % NOTE: it doesn't work, see CORE-1458
                    {running, Healthy}
            end;
        _TaskState ->
            true
    end.

-spec(handle_task_ip(jiffy:object()) -> [inet:ip_address()]).
handle_task_ip(TaskObj) ->
    Status = handle_task_status(TaskObj),
    NetworkInfos =
        mget([<<"container_status">>, <<"network_infos">>], Status, []),
    [ IPAddress ||
        NetworkInfo <- NetworkInfos,
        #{<<"ip_address">> := IP} <- mget(<<"ip_addresses">>, NetworkInfo),
        {ok, IPAddress} <- [inet:parse_strict_address(binary_to_list(IP))] ].

-spec(handle_task_ports(jiffy:object()) -> [task_port()] | undefined).
handle_task_ports(TaskObj) ->
    PortMappings = handle_task_port_mappings(TaskObj),
    DiscoveryPorts = handle_task_discovery_ports(TaskObj),
    merge_task_ports(PortMappings, DiscoveryPorts).

-spec(handle_task_port_mappings(jiffy:object()) -> [task_port()]).
handle_task_port_mappings(TaskObj) ->
    Type = mget([<<"container">>, <<"type">>], TaskObj, <<"HOST">>),
    handle_task_port_mappings(Type, TaskObj).

-spec(handle_task_port_mappings(binary(), jiffy:object()) -> [task_port()]).
handle_task_port_mappings(<<"HOST">>, _TaskObj) ->
    [];
handle_task_port_mappings(<<"MESOS">>, TaskObj) ->
    NetworkInfos = mget([<<"container">>, <<"network_infos">>], TaskObj, []),
    PortMappings =
        lists:flatmap(
            fun (NetworkInfo) ->
                mget(<<"port_mappings">>, NetworkInfo, [])
            end, NetworkInfos),
    handle_port_mappings(PortMappings);
handle_task_port_mappings(<<"DOCKER">>, TaskObj) ->
    DockerObj = mget([<<"container">>, <<"docker">>], TaskObj, #{}),
    PortMappings = mget(<<"port_mappings">>, DockerObj, []),
    handle_port_mappings(PortMappings).

-spec(handle_port_mappings(jiffy:object()) -> [task_port()]).
handle_port_mappings(PortMappings) when is_list(PortMappings) ->
    lists:map(fun handle_port_mappings/1, PortMappings);
handle_port_mappings(PortMapping) ->
    Protocol = handle_protocol(PortMapping),
    Port = mget(<<"container_port">>, PortMapping),
    HostPort = mget(<<"host_port">>, PortMapping),
    #{protocol => Protocol, port => Port, host_port => HostPort}.

-spec(handle_protocol(jiffy:object()) -> tcp | udp).
handle_protocol(Obj) ->
    case mget(<<"protocol">>, Obj) of
        <<"tcp">> -> tcp;
        <<"udp">> -> udp
    end.

-spec(handle_task_discovery_ports(jiffy:object()) -> [task_port()]).
handle_task_discovery_ports(TaskObj) ->
    Ports = mget([<<"discovery">>, <<"ports">>, <<"ports">>], TaskObj, []),
    lists:map(fun handle_task_discovery_port/1, Ports).

-spec(handle_task_discovery_port(jiffy:object()) -> task_port()).
handle_task_discovery_port(PortObj) ->
    Name = mget(<<"name">>, PortObj, undefined),
    Protocol = handle_protocol(PortObj),
    Port = mget(<<"number">>, PortObj),
    Labels = mget([<<"labels">>, <<"labels">>], PortObj, []),
    VIPLabels = handle_vip_labels(Labels),

    Result = #{protocol => Protocol},
    Result0 = mput(name, Name, Result),
    case handle_container_scope(Labels) of
        false when VIPLabels =:= [] ->
            mput(host_port, Port, Result0);
        false ->
            Result1 = mput(host_port, Port, Result0),
            mput(vip, {host, VIPLabels}, Result1);
        true when VIPLabels =:= [] ->
            mput(port, Port, Result0);
        true ->
            Result1 = mput(port, Port, Result0),
            mput(vip, VIPLabels, Result1)
    end.

-spec(handle_vip_labels(jiffy:object()) -> [binary()]).
handle_vip_labels(Labels) when is_list(Labels) ->
    lists:flatmap(fun handle_vip_labels/1, Labels);
handle_vip_labels(#{<<"key">> := <<"VIP", _/binary>>,
                    <<"value">> := VIP}) ->
    [VIP];
handle_vip_labels(#{<<"key">> := <<"vip", _/binary>>,
                    <<"value">> := VIP}) ->
    [VIP];
handle_vip_labels(_Label) ->
    [].

-spec(handle_container_scope(jiffy:object()) -> boolean()).
handle_container_scope(Labels) when is_list(Labels) ->
    lists:any(fun handle_container_scope/1, Labels);
handle_container_scope(#{<<"key">> := <<"network-scope">>,
                         <<"value">> := <<"container">>}) ->
    true;
handle_container_scope(_Label) ->
    false.

-spec(merge_task_ports([task_port()], [task_port()]) -> [task_port()]).
merge_task_ports(PortMappings, DiscoveryPorts) ->
    Ports =
        maps:from_list([ begin
            A = maps:get(protocol, TaskPort),
            B = maps:get(port, TaskPort, undefined),
            C = maps:get(host_port, TaskPort, undefined),
            {{A, B, C}, TaskPort}
        end || TaskPort <- DiscoveryPorts ]),
    Ports0 =
        lists:foldl(fun (TaskPort, Acc) ->
            A = maps:get(protocol, TaskPort),
            B = maps:get(port, TaskPort, undefined),
            C = maps:get(host_port, TaskPort, undefined),
            KeyA = {undefined, B, C},
            KeyB = {A, undefined, C},
            KeyC = {A, B, C},
            case {maps:find(KeyA, Acc), maps:find(KeyB, Acc)} of
                {{ok, TP}, error} ->
                    TP0 = maps:merge(TP, TaskPort),
                    maps:put(KeyA, TP0, Acc);
                {error, {ok, TP}} ->
                    TP0 = maps:merge(TP, TaskPort),
                    maps:put(KeyB, TP0, Acc);
                {error, error} ->
                    maps:put(KeyC, TaskPort, Acc)
            end
        end, Ports, PortMappings),
    maps:values(Ports0).

-spec(handle_task_status(jiffy:object()) -> jiffy:object()).
handle_task_status(#{<<"statuses">> := TaskStatuses}) ->
    [TaskStatus|_TaskStatuses0] =
    lists:sort(fun (#{<<"timestamp">> := A},
                    #{<<"timestamp">> := B}) ->
        A > B
    end, TaskStatuses),
    TaskStatus;
handle_task_status(TaskStatus) ->
    TaskStatus.

%%%===================================================================
%%% Subscribe Functions
%%%===================================================================

-spec(subscribe(pid()) -> {ok, MonRef, Tasks} | {error, atom()}
    when MonRef :: reference(), Tasks :: #{task_id() => task()}).
subscribe(Pid) ->
    Self = self(),
    MonRef = erlang:monitor(process, Pid),
    Pid ! {subscribe, Self, MonRef},
    receive
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, Reason};
        {error, MonRef, Reason} ->
            erlang:demonitor(MonRef, [flush]),
            {error, Reason};
        {ok, MonRef, Tasks} ->
            {ok, MonRef, Tasks}
    after 5000 ->
        erlang:demonitor(MonRef, [flush]),
        {error, timeout}
    end.

-spec(handle_subscribe(pid(), reference(), state()) -> state()).
handle_subscribe(Pid, Ref, State) ->
    case State of
        [] ->
            Pid ! {error, Ref, init},
            State;
        #state{subs=undefined} ->
            Pid ! {error, Ref, wait},
            State;
        #state{subs=#{Pid := _}} ->
            Pid ! {error, Ref, subscribed},
            State;
        #state{subs=Subs, tasks=T} ->
            Pid ! {ok, Ref, T},
            _MonRef = erlang:monitor(process, Pid),
            State#state{subs=maps:put(Pid, Ref, Subs)}
    end.

-spec(send_task(task_id(), task(), state()) -> state()).
send_task(_TaskId, _Task, #state{subs=undefined}=State) ->
    State;
send_task(TaskId, Task, #state{subs=Subs}=State) ->
    maps:fold(fun (Pid, Ref, ok) ->
        Pid ! {task_updated, Ref, TaskId, Task},
        ok
    end, ok, Subs),

    State.

%%%===================================================================
%%% Maps Functions
%%%===================================================================

-spec(mget([binary()] | binary(), jiffy:object()) -> jiffy:object()).
mget([], Obj) when is_binary(Obj) ->
    binary:copy(Obj);
mget([], Obj) ->
    Obj;
mget([Key | Tail], Obj) ->
    Obj0 = mget(Key, Obj),
    mget(Tail, Obj0);
mget(Key, Obj) ->
    maps:get(Key, Obj).

-spec(mget(Key, jiffy:object(), jiffy:object()) -> jiffy:object()
    when Key :: [binary()] | binary()).
mget(Keys, Obj, Default) ->
    try
        mget(Keys, Obj)
    catch error:{badkey, _Key} ->
        Default
    end.

-spec(mput(A, B, M) -> M
    when A :: term(), B :: term(), M :: #{A => B}).
mput(_Key, [], Map) ->
    Map;
mput(_Key, undefined, Map) ->
    Map;
mput(Key, Value, Map) ->
    maps:put(Key, Value, Map).

-spec(mremove(A, M) -> M
    when A :: term(), B :: term(), M :: #{A => B}).
mremove(Key, Map) ->
    maps:remove(Key, Map).

-spec(mdiff(map(), map()) -> map()).
mdiff(A, B) ->
    maps:fold(fun(K, V, Acc) ->
        case maps:get(K, Acc) of
            V -> maps:remove(K, Acc);
            _ -> Acc
        end
    end, B, A).

%%%===================================================================
%%% Mesos Operator API Client
%%%===================================================================

-spec(handle_init() -> {ok, state()} | {error, term()}).
handle_init() ->
    Body = jiffy:encode(#{type => <<"SUBSCRIBE">>}),
    ContentType = "application/json",
    Request = {"/api/v1", [], ContentType, Body},
    {ok, Ref} =
        dcos_net_mesos:request(
            post, Request, [{timeout, infinity}],
            [{sync, false}, {stream, {self, once}}]),
    receive
        {http, {Ref, {{_HTTPVersion, 307, _StatusStr}, _Headers, _Body}}} ->
            {error, redirect};
        {http, {Ref, {{_HTTPVersion, Status, _StatusStr}, _Headers, _Body}}} ->
            {error, {http_status, Status}};
        {http, {Ref, {error, Error}}} ->
            {error, Error};
        {http, {Ref, stream_start, _Headers, Pid}} ->
            httpc:stream_next(Pid),
            erlang:monitor(process, Pid),
            {ok, #state{pid=Pid, ref=Ref}}
    after 5000 ->
        ok = httpc:cancel_request(Ref),
        {error, timeout}
    end.

-spec(stream(binary(), State) -> {error, term()} |
    {next, State} | {next, binary(), State}
        when State :: state()).
stream(Data, #state{pid=Pid, size=undefined, buf=Buf}=State) ->
    Buf0 = <<Buf/binary, Data/binary>>,
    case binary:split(Buf0, <<"\n">>) of
        [SizeBin, Tail] ->
            Size = binary_to_integer(SizeBin),
            State0 = State#state{size=Size, buf= <<>>},
            stream(Tail, State0);
        [Buf0] when byte_size(Buf0) > 12 ->
            {error, {bad_format, Buf0}};
        [Buf0] ->
            httpc:stream_next(Pid),
            {next, State#state{buf=Buf0}}
    end;
stream(Data, #state{pid=Pid, size=Size, buf=Buf}=State) ->
    Buf0 = <<Buf/binary, Data/binary>>,
    case byte_size(Buf0) of
        BufSize when BufSize >= Size ->
            <<Head:Size/binary, Tail/binary>> = Buf0,
            State0 = State#state{size=undefined, buf=Tail},
            try jiffy:decode(Head, [return_maps]) of Obj ->
                {next, Obj, State0}
            catch error:Error ->
                {error, Error}
            end;
        _BufSize ->
            httpc:stream_next(Pid),
            {next, State#state{buf=Buf0}}
    end.