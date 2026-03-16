-module(jet_platform_ffi).
-export([activate_platform/1, resolve_need/1, with_overrides/2]).

%% Store a platform's provider map in the process dictionary.
%% PlatformMap is a map of NeedName (atom) => ImplementationModule (atom).
activate_platform(PlatformMap) ->
    erlang:put(jet_needs, PlatformMap).

%% Resolve a need name to its current implementation module.
resolve_need(NeedName) ->
    case erlang:get(jet_needs) of
        undefined -> error({no_platform_active, NeedName});
        Map ->
            case maps:find(NeedName, Map) of
                {ok, Impl} -> Impl;
                error -> error({unresolved_need, NeedName})
            end
    end.

%% Run Fun with temporary need overrides, then restore original needs.
%% Overrides is a map of NeedName => MockModule.
with_overrides(Overrides, Fun) ->
    Old = erlang:get(jet_needs),
    Merged = maps:merge(
        case Old of undefined -> #{}; V -> V end,
        Overrides
    ),
    erlang:put(jet_needs, Merged),
    try Fun()
    after
        case Old of
            undefined -> erlang:erase(jet_needs);
            _ -> erlang:put(jet_needs, Old)
        end
    end.
