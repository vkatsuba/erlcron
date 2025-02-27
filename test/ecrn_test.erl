%%% @copyright Erlware, LLC. All Rights Reserved.
%%%
%%% This file is provided to you under the BSD License; you may not use
%%% this file except in compliance with the License.
-module(ecrn_test).
-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

-define(FuncTest(A), {atom_to_list(A), fun A/0}).

%%%===================================================================
%%% Types
%%%===================================================================
cron_test_() ->
    {setup,
     fun() ->
             application:load(erlcron),
             application:set_env(erlcron, sup_intensity, 0),
             application:set_env(erlcron, sup_period,    1),
             application:start(erlcron)
     end,
     fun(_) ->
             application:stop(erlcron)
     end,
     [{timeout, 30, [
       ?FuncTest(set_alarm),
       ?FuncTest(travel_back_in_time),
       ?FuncTest(cancel_alarm),
       ?FuncTest(big_time_jump),
       ?FuncTest(cron),
       ?FuncTest(validation)
      ]},
      {timeout, 30, [
       ?FuncTest(weekly)
      ]},
      {timeout, 30, [
       ?FuncTest(weekly_every)
      ]}
     ]}.

set_alarm() ->
    erlcron:set_datetime({{2000,1,1},{8,0,0}}),

    Self = self(),

    erlcron:at(test1, {9,0,0}, fun() -> Self ! ack1 end),
    erlcron:at(test2, {9,0,1}, fun() -> Self ! ack2 end),
    erlcron:daily(test3, {every, {1,s}, {between, {9,0,2}, {9,0,4}}},
                         fun() -> Self ! ack3 end),

    erlcron:set_datetime({{2000,1,1},{8,59,59}}),

    %% The alarm should trigger this nearly immediately.
    ?assertMatch(1, collect(ack1, 1500, 1)),

    %% The alarm should trigger this 1 second later.
    ?assertMatch(1, collect(ack2, 2500, 1)),

    %% The alarm should trigger this 1 second later.
    ?assertMatch(3, collect(ack3, 3000, 3)),

    erlcron:cancel(test3).

cancel_alarm() ->
    Day = {2000,1,1},
    erlcron:set_datetime({Day,{8,0,0}}),
    AlarmTimeOfDay = {9,0,0},

    Self = self(),

    Ref = erlcron:at(AlarmTimeOfDay, fun(_, _) ->
                                               Self ! ack
                                     end),
    erlcron:cancel(Ref),
    erlcron:set_datetime({Day, AlarmTimeOfDay}),
    ?assertMatch(0, collect(ack, 125, 1)).

%% Time jumps ahead one day so we should see the alarms from both days.
big_time_jump() ->
    Day1 = {2000,1,1},
    Day2 = {2000,1,2},
    EpochDateTime = {Day1,{8,0,0}},
    erlcron:set_datetime(EpochDateTime),
    Alarm1TimeOfDay = {9,0,0},
    Alarm2TimeOfDay = {9,0,1},

    Self = self(),

    erlcron:daily(Alarm1TimeOfDay, fun(_, _) -> Self ! ack1 end),
    erlcron:daily(Alarm2TimeOfDay, fun(_, _) -> Self ! ack2 end),
    erlcron:set_datetime({Day2, {9, 10, 0}}),
    ?assertMatch(1, collect(ack1, 1500, 1)),
    ?assertMatch(1, collect(ack2, 1500, 1)),
    ?assertMatch(1, collect(ack1, 1500, 1)),
    ?assertMatch(1, collect(ack2, 1500, 1)).

travel_back_in_time() ->
    Seconds = seconds_now(),
    Past = {{2000,1,1},{12,0,0}},
    erlcron:set_datetime(Past),
    {ExpectedDateTime, _} = erlcron:datetime(),
    ExpectedSeconds = calendar:datetime_to_gregorian_seconds(ExpectedDateTime),
    ?assertMatch(true, ExpectedSeconds =< calendar:datetime_to_gregorian_seconds(Past)),
    ?assertMatch(true, ExpectedSeconds < Seconds).


%% Time jumps ahead one day so we should see the alarms from both days.
cron() ->
    Day1 = {2000,1,1},
    AlarmTimeOfDay = {15,29,58},
    erlcron:set_datetime({Day1, AlarmTimeOfDay}),

    Self = self(),

    Job = {{daily, {3, 30, pm}},
            fun(_, _) ->
                    Self ! ack
            end},

    erlcron:cron(Job),

    ?assertMatch(1, collect(ack, 2500, 1)).

validation() ->
    erlcron:set_datetime({{2000,1,1}, {15,0,0}}),
    ?assertMatch(ok, ecrn_agent:validate({once, {3, 30, pm}})),
    erlcron:set_datetime({{2000,1,1}, {15,31,0}}),
    ?assertMatch({error,{specified_time_past_seconds_ago, -60}},
                 ecrn_agent:validate({once, {3, 30, pm}})),

    ?assertMatch(ok, ecrn_agent:validate({once, 3600})),
    ?assertMatch(ok, ecrn_agent:validate({daily, {every, {0,s}}})),
    ?assertMatch(ok, ecrn_agent:validate({daily, {every, {23,s}}})),
    ?assertMatch(ok, ecrn_agent:validate({daily, {every, {23,sec},
                                                     {between, {3, pm}, {3, 30, pm}}}})),
    ?assertMatch(ok, ecrn_agent:validate({daily, {3, 30, pm}})),
    ?assertMatch(ok, ecrn_agent:validate({weekly, thu, {2, am}})),
    ?assertMatch(ok, ecrn_agent:validate({weekly, wed, {2, am}})),
    ?assertMatch(ok, ecrn_agent:validate({weekly, fri, {every, {5,sec}}})),
    ?assertMatch(ok, ecrn_agent:validate({monthly, 1, {2, am}})),
    ?assertMatch(ok, ecrn_agent:validate({monthly, 4, {2, am}})),
    ?assertMatch({error,{invalid_time,{55,22,am}}},
                    ecrn_agent:validate({daily, {55, 22, am}})),
    ?assertMatch({error,{invalid_days_in_schedule,{monthly,"A",{55,am}}}},
                    ecrn_agent:validate({monthly, 65, {55, am}})).

weekly() ->
    DateF = fun (Offset) -> {2000, 1, 1 + Offset} end,
    erlcron:set_datetime({DateF(0), {7,0,0}}),
    Self = self(),
    erlcron:cron(weekly, {{weekly, [sat, sun], {9,0,0}}, fun() -> Self ! weekly end}),
    Pattern = [1, 1, 0, 0, 0, 0, 0, 1],
    collect_weekly(DateF, {8, 0, 0}, {10, 0, 0}, Pattern),
    erlcron:cancel(weekly).

weekly_every() ->
    DateF = fun (Offset) -> {2000, 1, 1 + Offset} end,
    erlcron:set_datetime({DateF(0), {7,0,0}}),
    Self = self(),
    erlcron:cron(weekly, {{weekly, [sat, mon],
                           {every, {29, sec}, {between, {9, 0, 0}, {9, 1, 0}}}},
                          fun() -> Self ! weekly end}),
    Pattern = [3, 0, 3, 0, 0, 0, 0, 3],
    collect_weekly(DateF, {8, 0, 0}, {10, 0, 0}, Pattern),
    erlcron:cancel(weekly).

%%%===================================================================
%%% Internal Functions
%%%===================================================================
seconds_now() ->
    calendar:datetime_to_gregorian_seconds(calendar:universal_time()).

collect(Msg, Timeout, Count) ->
    collect(Msg, Timeout, 0, Count).
collect(_Msg, _Timeout, Count, Count) ->
    Count;
collect(Msg, Timeout, I, Count) ->
    receive
        Msg     -> collect(Msg, Timeout, I+1, Count)
    after
        Timeout -> I
    end.

% check that for each day generated by DateF(I) for increasing I, Pattern[I]
% weekly messages are received
collect_weekly(DateF, TimeBefore, TimeAfter, Pattern) ->
    collect_weekly(DateF, TimeBefore, TimeAfter, Pattern, 0).

collect_weekly(DateF, TimeBefore, TimeAfter, [N | PatternTail], I) ->
    erlcron:set_datetime({DateF(I), TimeBefore}),
    ?assertMatch(0, collect(weekly, 1000, 1)),
    erlcron:set_datetime({DateF(I), TimeAfter}),
    ?assertMatch(N, collect(weekly, 1000, N)),
    collect_weekly(DateF, TimeBefore, TimeAfter, PatternTail, I+1);
collect_weekly(_DateF, _TimeBefore, _TimeAfter, [], _I) -> ok.
