%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_limiter).

-behaviour(gen_server).

-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([start_link/1]).
-export([limit/2, can_send/2, ack/2, register/2, unregister/2]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(limit/2 :: (pid(), non_neg_integer()) -> 'ok').
-spec(can_send/2 :: (pid(), pid()) -> bool()).
-spec(ack/2 :: (pid(), non_neg_integer()) -> 'ok').
-spec(register/2 :: (pid(), pid()) -> 'ok').
-spec(unregister/2 :: (pid(), pid()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

-record(lim, {prefetch_count = 0,
              ch_pid,
              queues = dict:new(),
              in_use = 0}).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

start_link(ChPid) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [ChPid], []),
    Pid.

limit(LimiterPid, PrefetchCount) ->
    gen_server:cast(LimiterPid, {limit, PrefetchCount}).

%% Ask the limiter whether the queue can deliver a message without
%% breaching a limit
can_send(LimiterPid, QPid) ->
    gen_server:call(LimiterPid, {can_send, QPid}).

%% Let the limiter know that the channel has received some acks from a
%% consumer
ack(LimiterPid, Count) ->
    gen_server:cast(LimiterPid, {ack, Count}).

register(LimiterPid, QPid) ->
    gen_server:cast(LimiterPid, {register, QPid}).

unregister(LimiterPid, QPid) ->
    gen_server:cast(LimiterPid, {unregister, QPid}).

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([ChPid]) ->
    {ok, #lim{ch_pid = ChPid} }.

handle_call({can_send, _QPid}, _From, State = #lim{in_use = InUse}) ->
    case limit_reached(State) of
        true  -> 
            %% TODO: keep track of the fact that the specific QPid has
            %% had a can_send request rejected, so we can restrict the
            %% notifications to these QPids only.
            {reply, false, State};
        false -> {reply, true, State#lim{in_use = InUse + 1}}
    end.

handle_cast({limit, PrefetchCount}, State) ->
    {noreply, maybe_notify(State, State#lim{prefetch_count = PrefetchCount})};

handle_cast({ack, Count}, State = #lim{in_use = InUse}) ->
    NewInUse = if InUse == 0 -> 0;
                  true       -> InUse - Count
               end,
    {noreply, maybe_notify(State, State#lim{in_use = NewInUse})};

handle_cast({register, QPid}, State) ->
    {noreply, remember_queue(QPid, State)};

handle_cast({unregister, QPid}, State) ->
    {noreply, forget_queue(QPid, State)}.

handle_info({'DOWN', _MonitorRef, _Type, QPid, _Info}, State) ->
    {noreply, forget_queue(QPid, State)}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    State.

%%----------------------------------------------------------------------------
%% Internal plumbing
%%----------------------------------------------------------------------------

maybe_notify(OldState, NewState) ->
    case limit_reached(OldState) andalso not(limit_reached(NewState)) of
        true  -> ok = notify_queues(NewState#lim.ch_pid, NewState#lim.queues);
        false -> ok
    end,
    NewState.

limit_reached(#lim{prefetch_count = Limit, in_use = InUse}) ->
    Limit =/= 0 andalso InUse >= Limit.

remember_queue(QPid, State = #lim{queues = Queues}) ->
    case dict:is_key(QPid, Queues) of
        false -> MonitorRef = erlang:monitor(process, QPid),
                 State#lim{queues = dict:store(QPid, MonitorRef, Queues)};
        true  -> State
    end.

forget_queue(QPid, State = #lim{ch_pid = ChPid, queues = Queues}) ->
    case dict:find(QPid, Queues) of
        {ok, MonitorRef} ->
            true = erlang:demonitor(MonitorRef),
            ok = rabbit_amqqueue:unblock(QPid, ChPid),
            State#lim{queues = dict:erase(QPid, Queues)};
        error -> State
    end.

notify_queues(ChPid, Queues) ->
    QList = dict:to_list(Queues),
    case length(QList) of
        0 -> ok;
        L ->
            %% We randomly vary the position in which each queue
            %% appears in the list, thus ensuring that each queue has
            %% an equal chance of being notified first.
            {L1, L2} = lists:split(random:uniform(L), QList),
            [ok = rabbit_amqqueue:unblock(Q, ChPid) || {Q, _} <- L2 ++ L1],
            ok
    end.
