%%% -*- coding: utf-8; Mode: erlang; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*-
%%% ex: set softtabstop=4 tabstop=4 shiftwidth=4 expandtab fileencoding=utf-8:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI ZeroMQ Integration==
%%% Provide a way of sending/receiving through ZeroMQ.
%%% @end
%%%
%%% BSD LICENSE
%%% 
%%% Copyright (c) 2011, Michael Truog <mjtruog at gmail dot com>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in
%%%       the documentation and/or other materials provided with the
%%%       distribution.
%%%     * All advertising materials mentioning features or use of this
%%%       software must display the following acknowledgment:
%%%         This product includes software developed by Michael Truog
%%%     * The name of the author may not be used to endorse or promote
%%%       products derived from this software without specific prior
%%%       written permission
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%% CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
%%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
%%% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
%%% DAMAGE.
%%%
%%% @author Michael Truog <mjtruog [at] gmail (dot) com>
%%% @copyright 2011 Michael Truog
%%% @version 0.1.3 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_job_zeromq).
-author('mjtruog [at] gmail (dot) com').

-behaviour(cloudi_job).

%% external interface

%% cloudi_job callbacks
-export([cloudi_job_init/3,
         cloudi_job_handle_request/8,
         cloudi_job_handle_info/3,
         cloudi_job_terminate/2]).

-include("cloudi_logger.hrl").

-record(state,
    {
        context,
        publish,     % NameInternal -> [{NameExternal, Socket} | _]
        subscribe,   % Socket -> [{BinaryMax, BinaryPattern,
                     %             NameExternal -> NameInternal} | _]
        request,     % Name -> Socket
        reply,       % Socket -> Name
        request_replies = dict:new(),  % Socket -> F(Response)
        reply_replies = dict:new()     % TransId -> Socket
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_job
%%%------------------------------------------------------------------------

cloudi_job_init(Args, Prefix, Dispatcher) ->
    {SubscribeL, L1} = proplists2:partition(subscribe, Args),
    {PublishL, L2} = proplists2:partition(publish, L1),
    {RequestL, L3} = proplists2:partition(outbound, L2),
    {ReplyL, []} = proplists2:partition(inbound, L3),

    {ok, Context} = erlzmq:context(),
    Publish = lists:foldl(fun({publish,
                               {[{[I1a | _], [I1b | _]} | _] = NamePairL,
                                [[I2 | _] | _] = EndpointL}}, D) ->
        true = is_integer(I1a) and is_integer(I1b) and is_integer(I2),
        {ok, S} = erlzmq:socket(Context, pub),
        lists:foreach(fun(Endpoint) ->
            ok = erlzmq:bind(S, Endpoint)
        end, EndpointL),
        lists:foldl(fun({NameInternal, NameExternal}, DD) ->
            cloudi_job:subscribe(Dispatcher, NameInternal),
            trie:append(Prefix ++ NameInternal,
                        {erlang:list_to_binary(NameExternal), S}, DD)
        end, D, NamePairL)
    end, trie:new(), PublishL),
    Subscribe = lists:foldl(fun({subscribe,
                                 {[{[I1a | _], [I1b | _]} | _] = NamePairL,
                                  [[I2 | _] | _] = EndpointL}}, D) ->
        true = is_integer(I1a) and is_integer(I1b) and is_integer(I2),
        {ok, S} = erlzmq:socket(Context, sub),
        lists:foreach(fun(Endpoint) ->
            ok = erlzmq:connect(S, Endpoint)
        end, EndpointL),
        NameLookup = lists:foldl(fun({NameInternal, NameExternal}, DD) ->
            NameExternalBin = erlang:list_to_binary(NameExternal),
            ok = erlzmq:setsockopt(S, subscribe, NameExternalBin),
            dict:append(NameExternalBin, Prefix ++ NameInternal, DD)
        end, dict:new(), NamePairL),
        NameL = dict:fetch_keys(NameLookup),
        NameMax = lists:foldl(fun(N, M) ->
            erlang:max(erlang:byte_size(N), M)
        end, 0, NameL),
        dict:store(S, {NameMax, binary:compile_pattern(NameL), NameLookup}, D)
    end, dict:new(), SubscribeL),
    Request = lists:foldl(fun({outbound,
                               {[I1 | _] = Name,
                                [I2 | _] = Endpoint}}, D) ->
        true = is_integer(I1) and is_integer(I2),
        cloudi_job:subscribe(Dispatcher, Name),
        {ok, S} = erlzmq:socket(Context, req),
        ok = erlzmq:bind(S, Endpoint),
        trie:store(Prefix ++ Name, S, D)
    end, trie:new(), RequestL),
    Reply = lists:foldl(fun({inbound,
                             {[I1 | _] = Name,
                              [I2 | _] = Endpoint}}, D) ->
        true = is_integer(I1) and is_integer(I2),
        {ok, S} = erlzmq:socket(Context, rep),
        ok = erlzmq:connect(S, Endpoint),
        dict:store(S, Prefix ++ Name, D)
    end, dict:new(), ReplyL),
    {ok, #state{context = Context,
                publish = Publish,
                subscribe = Subscribe,
                request = Request,
                reply = Reply}}.

cloudi_job_handle_request(Type, Name, Request, Timeout, TransId, Pid,
                          #state{publish = PublishZMQ,
                                 request = RequestZMQ,
                                 request_replies = RequestReplies} = State,
                          Dispatcher) ->
    true = is_binary(Request),
    case trie:find(Name, PublishZMQ) of
        {ok, SL} ->
            lists:foreach(fun({NameZMQ, S}) ->
                ?LOG_TRACE("ZeroMQ publish as ~p from ~p: ~p",
                           [NameZMQ, Name, Request]),
                ok = erlzmq:send(S, erlang:iolist_to_binary([NameZMQ, Request]))
            end, SL);
        error ->
            ok
    end,
    case trie:find(Name, RequestZMQ) of
        {ok, RequestS} ->
            ?LOG_TRACE("request sent as ~p: ~p", [Name, Request]),
            ok = erlzmq:send(RequestS, Request),
            F = fun(Response) ->
                ?LOG_TRACE("request recv as ~p: ~p", [Name, Response]),
                cloudi_job:return_nothrow(Dispatcher, Type, Name, Response,
                                          Timeout, TransId, Pid)
            end,
            NewRequestReplies = dict:store(RequestS, F, RequestReplies),
            % do not enforce a timeout here, rely on the
            % receiving CloudI service timeout
            {noreply, State#state{request_replies = NewRequestReplies}};
        error ->
            % successful publish operations don't need to store a response
            % erroneous synchronous operations will get a timeout
            {reply, <<>>, State}
    end.

cloudi_job_handle_info({zmq, S, Incoming},
                       #state{subscribe = SubscribeZMQ,
                              reply = ReplyZMQ,
                              request_replies = RequestReplies,
                              reply_replies = ReplyReplies} = State,
                       Dispatcher) ->
    case dict:find(S, RequestReplies) of
        {ok, F} ->
            F(Incoming),
            {noreply,
             State#state{request_replies = dict:erase(S, RequestReplies)}};
        error ->
            case dict:find(S, ReplyZMQ) of
                {ok, Name} ->
                    ?LOG_TRACE("reply sent as ~p: ~p", [Name, Incoming]),
                    case cloudi_job:send_async_active(Dispatcher,
                                                      Name, Incoming) of
                        {ok, TransId} ->
                            {noreply,
                             State#state{reply_replies =
                                         dict:store(TransId, S, ReplyReplies)}};
                        {error, _} ->
                            ok = erlzmq:send(S, <<>>),
                            {noreply, State}
                    end;
                error ->
                    {Max, Pattern, Lookup} = dict:fetch(S, SubscribeZMQ),
                    {0, Length} = binary:match(Incoming, Pattern,
                                               [{scope, {0, Max}}]),
                    {NameZMQ, Request} = erlang:split_binary(Incoming, Length),
                    lists:foreach(fun(Name) ->
                        ?LOG_TRACE("subscribe from ~p to ~p: ~p",
                                   [NameZMQ, Name, Request]),
                        cloudi_job:send_async(Dispatcher, Name, Request)
                    end, dict:fetch(NameZMQ, Lookup)),
                    {noreply, State}
            end
    end;

cloudi_job_handle_info({'return_async_active', Name, Response,
                        _Timeout, TransId},
                       #state{reply_replies = ReplyReplies} = State,
                       _Dispatcher) ->
    ?LOG_TRACE("reply recv as ~p: ~p (~p)", [Name, Response, TransId]),
    true = is_binary(Response),
    S = dict:fetch(TransId, ReplyReplies),
    ok = erlzmq:send(S, Response),
    {noreply, State#state{reply_replies = dict:erase(TransId, ReplyReplies)}};

cloudi_job_handle_info({'timeout_async_active', TransId},
                       #state{reply_replies = ReplyReplies} = State,
                       _Dispatcher) ->
    ?LOG_TRACE("reply recv timeout (~p)", [TransId]),
    S = dict:fetch(TransId, ReplyReplies),
    ok = erlzmq:send(S, <<>>),
    {noreply, State#state{reply_replies = dict:erase(TransId, ReplyReplies)}};

cloudi_job_handle_info(Request, State, _) ->
    ?LOG_WARN("Unknown info \"~p\"", [Request]),
    {noreply, State}.

cloudi_job_terminate(_, #state{context = Context}) ->
    erlzmq:term(Context),
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

