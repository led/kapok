%% Helper module for dispatching names(module/function/macro/var) and their references.
-module(kapok_dispatch).
-export([default_requires/0,
         default_uses/0,
         find_module/3,
         find_local_macro/5,
         find_remote_macro/6,
         find_local_function/2,
         find_imported_local_function/3,
         find_remote_function/4,
         is_macro_loaded/3,
         filter_fa/2,
         format_error/1]).
-import(kapok_ctx, [metadata_check_remote_call/1]).
-include("kapok.hrl").

default_requires() ->
  L = [{'kapok_macro', 'kapok_macro'}],
  orddict:from_list(L).

default_uses() ->
  [{'kapok.core', 'core'},
   {'kapok.protocol', 'protocol'}].

%% get the original module name in case module is an alias or rename.
find_module(_Meta, Module, Ctx) ->
  Requires = ?m(Ctx, requires),
  case orddict:find(Module, Requires) of
    {ok, M1} -> M1;
    error -> Module
  end.

%% find local/remote macro/function

find_local_macro(Meta, FunArity, FunMeta, Args, #{namespace := Namespace} = Ctx) ->
  %% check whether the FunArity refers to a macro in current namespace
  %% which is defined previously.
  Macros = kapok_symbol_table:namespace_macros(Namespace),
  case filter_fa(FunArity, Macros) of
    [{F, A, P}] ->
      {{local, {F, A, P}}, Ctx};
    [] ->
      find_import_macro(Meta, FunArity, FunMeta, Args, Ctx)
  end.

find_import_macro(Meta, FunArity, FunMeta, Args, Ctx) ->
  {D, Ctx1} = find_dispatch(Meta, FunArity, Ctx),
  R = case D of
        {macro, MFAP} ->
          {remote, MFAP};
        {function, {M, F, A, P}} ->
          rewrite_function(Meta, M, F, FunMeta, A, P, Args);
        false ->
          false
      end,
  {R, Ctx1}.

find_remote_macro(Meta, Module, FunArity, FunMeta, Args, Ctx) ->
  Original = find_module(Meta, Module, Ctx),
  Uses = ?m(Ctx, uses),
  case orddict:find(Original, Uses) of
    {ok, _} ->
      %% Original is declared in ns use clause.
      %% Load all the import macros/functions from the specified module if necessary,
      %% and then find the specified FunArity.
      {D, Ctx1} = find_dispatch(Meta, Original, FunArity, Ctx),
      case D of
        {macro, MFAP} ->
          {{remote, MFAP}, Ctx1};
        {function, {M, F, A, P}} ->
          {rewrite_function(Meta, M, F, FunMeta, A, P, Args), Ctx1};
        false ->
          find_optional_remote_macro(Meta, Original, FunArity, FunMeta, Args, Ctx1)
      end;
    error ->
      find_optional_remote_macro(Meta, Original, FunArity, FunMeta, Args, Ctx)
  end.

find_optional_remote_macro(Meta, Module, FunArity, FunMeta, Args, Ctx) ->
  {D, Ctx1} = find_optional_dispatch(Meta, Module, FunArity, Ctx),
  R = case D of
        {macro, MFAP} ->
          {remote, MFAP};
        {function, {M, F, A, P}} ->
          rewrite_function(Meta, M, F, FunMeta, A, P, Args);
        unknown_module ->
          false;
        false ->
          false
      end,
  {R, Ctx1}.

find_local_function(FunArity, #{def_fap := FAP} = Ctx) ->
  case filter_fa(FunArity, [FAP]) of
    [{F, A, P}] ->
      %% match current function definition
      {F, A, P};
    [] ->
      %% find in macros/functions of current namespace
      Namespace = maps:get(namespace, Ctx),
      Locals = kapok_symbol_table:namespace_locals(Namespace),
      case filter_fa(FunArity, Locals) of
        [{F, A, P}] -> {F, A, P};
        [] -> false
      end
  end.

find_imported_local_function(Meta, FunArity, Ctx) ->
  {D, Ctx1} = find_dispatch(Meta, FunArity, Ctx),
  R = case D of
        {Tag, MFAP} when Tag == macro; Tag == function -> MFAP;
        false -> false
      end,
  {R, Ctx1}.

find_remote_function(Meta, Module, FunArity, Ctx) ->
  Original = find_module(Meta, Module, Ctx),
  Uses = ?m(Ctx, uses),
  case orddict:find(Original, Uses) of
    {ok, _} ->
      {D, Ctx1} = find_dispatch(Meta, Original, FunArity, Ctx),
      case D of
        {Tag, MFAP} when Tag == macro; Tag == function ->
          {MFAP, Ctx1};
        false ->
          find_optional_remote_function(Meta, Original, FunArity, Ctx1)
      end;
    error ->
      find_optional_remote_function(Meta, Original, FunArity, Ctx)
  end.

find_optional_remote_function(Meta, Module, {Fun, Arity} = FunArity, Ctx) ->
  {D, Ctx1} = find_optional_dispatch(Meta, Module, FunArity, Ctx),
  R = case D of
        {Tag, MFAP} when Tag == macro; Tag == function ->
          MFAP;
        unknown_module ->
          case metadata_check_remote_call(Ctx) of
            true -> false;
            _ -> {Module, Fun, Arity, 'normal'}
          end;
        Atom when is_atom(Atom) ->
          Atom
      end,
  {R, Ctx1}.

is_macro_loaded(Module, FAP, Ctx) ->
  lists:member(FAP, get_macros([], Module, Ctx)).

find_optional_dispatch(Meta, Module, FunArity, Ctx) ->
  case code:ensure_loaded(Module) of
    {module, Module} ->
      FunImports = orddict:from_list([{Module, get_optional_functions(Module)}]),
      MacroImports = orddict:from_list([{Module, get_optional_macros(Module)}]),
      do_find_dispatch(Meta, FunArity, FunImports, MacroImports, Ctx);
    {error, _} ->
      {unknown_module, Ctx}
  end.

find_dispatch(Meta, Module, FunArity, Ctx) ->
  Ctx1 = ensure_uses_imported(Ctx),
  %% TODO check whether module is a require alias
  FunList = case orddict:find(Module, ?m(Ctx1, functions)) of
                                   {ok, L1} -> L1;
                                   error -> []
          end,
  FunImports = orddict:from_list([{Module, FunList}]),
  MacroList = case orddict:find(Module, ?m(Ctx1, macros)) of
                {ok, L2} -> L2;
                error -> []
              end,
  MacroImports = orddict:from_list([{Module, MacroList}]),
  do_find_dispatch(Meta, FunArity, FunImports, MacroImports, Ctx1).

find_dispatch(Meta, FunArity, Ctx) ->
  Ctx1 = ensure_uses_imported(Ctx),
  do_find_dispatch(Meta, FunArity, ?m(Ctx1, functions), ?m(Ctx1, macros), Ctx1).

do_find_dispatch(Meta, {Fun, Arity} = FunArity, FunImports, MacroImports, Ctx) ->
  FunMatch = filter_import(FunArity, FunImports),
  MacroMatch = filter_import({Fun, Arity}, MacroImports),
  case {FunMatch, MacroMatch} of
    {[], [Match]} ->
      {M, [{F, A, P}]} = Match,
      {{macro, {M, F, A, P}}, Ctx};
    {[Match], []} ->
      {M, [{F, A, P}]} = Match,
      {{function, {M, F, A, P}}, Ctx};
    {[], []} ->
      {false, Ctx};
    _ ->
      [First, Second | _T] = FunMatch ++ MacroMatch,
      Error = {ambiguous_call, {Fun, Arity, First, Second}},
      kapok_error:form_error(Meta, ?m(Ctx, file), ?MODULE, Error)
  end.

filter_import(FunArity, List) when is_list(List) ->
  lists:foldl(fun({Module, Imports}, Acc) ->
                  case filter_fa(FunArity, Imports) of
                    [] -> Acc;
                    R -> orddict:store(Module, R, Acc)
                  end
              end,
              [],
              List).

filter_fa({Fun, Arity} = FunArity, FAList) when is_list(FAList) ->
  ordsets:fold(
      fun({F, A} = FA, Acc) when is_number(A) andalso FA == FunArity ->
          [{F, A, 'normal'} | Acc];
         ({Alias, {F, A, P}}, Acc) when (P == 'normal' orelse P == 'key'), {Alias, A} == FunArity ->
          [{F, A, P} | Acc];
         ({Alias, {F, A, 'rest'}}, Acc) when (Alias == Fun) andalso (A =< Arity) ->
          [{F, A, 'rest'} | Acc];
         ({F, A, P} = FAP, Acc) when (P == 'normal' orelse P == 'key'), {F, A} == FunArity ->
          [FAP | Acc];
         ({F, A, 'rest'} = FAP, Acc) when (F == Fun) andalso (A =< Arity) ->
          [FAP | Acc];
         (_, Acc) ->
          Acc
      end,
      [],
      FAList).

ensure_uses_imported(#{uses := Uses} = Ctx) ->
  lists:foldl(fun({Module, Args}, C) ->
                  {ok, Meta} = orddict:find(meta, Args),
                  case module_is_imported(Module, C) of
                    true -> C;
                    false -> import_module(Meta, Module, Args, C)
                  end
              end,
              Ctx,
              Uses).

module_is_imported(Module, #{functions := Functions, macros := Macros}) ->
  orddict:is_key(Module, Functions) orelse orddict:is_key(Module, Macros).

import_module(Meta, Module, Args, Ctx) ->
  {Functions, Macros} = get_exports(Meta, Module, Args, Ctx),
  Ctx1 = case Functions of
           [] -> Ctx;
           _ -> kapok_ctx:add_function(Meta, Ctx, Module, Functions)
         end,
  Ctx2 = case Macros of
           [] -> Ctx1;
           _ -> kapok_ctx:add_macro(Meta, Ctx1, Module, Macros)
         end,
  Ctx2.

get_exports(Meta, Module, Args, Ctx) ->
  Functions = get_functions(Meta, Module, Ctx),
  Macros = get_macros(Meta, Module, Ctx),
  {filter_exports(Functions, Args),
   filter_exports(Macros, Args)}.

ensure_loaded(Meta, Module, Ctx) ->
  case code:ensure_loaded(Module) of
    {module, Module} ->
      ok;
    {error, What} ->
      kapok_error:compile_error(Meta, ?m(Ctx, file),
                                "fail to load module: ~p due to load error: ~p", [Module, What])
  end.

get_optional_functions(Module) ->
  Fun = fun({F, A}) -> {F, A, 'normal'};
           ({_F, _A, _P} = FAP) -> FAP
        end,
  try
    L = Module:'__info__'(functions),
    ordsets:from_list(lists:map(Fun, L))
  catch
    error:undef ->
      try
        L1 = Module:module_info(exports),
        ordsets:from_list(lists:map(Fun, L1))
      catch
        error:undef -> []
      end
  end.

get_functions(Meta, Module, Ctx) ->
  ensure_loaded(Meta, Module, Ctx),
  Fun = fun({F, A}) -> {F, A, 'normal'};
           ({_F, _A, _P} = FAP) -> FAP
        end,
  try
    L = Module:'__info__'(functions),
    ordsets:from_list(lists:map(Fun, L))
  catch
    error:undef ->
      try
        L1 = Module:module_info(exports),
        ordsets:from_list(lists:map(Fun, L1))
      catch
        error:undef ->
          kapok_error:compile_error(Meta, ?m(Ctx, file),
                                    "fail to get exports for unloaded module: ~p", [Module])
      end
  end.

get_optional_macros(Module) ->
  try
    L = Module:'__info__'(macros),
    Fun = fun({F, A}) -> {F, A, 'normal'};
           ({_F, _A, _P} = FAP) -> FAP
          end,
    ordsets:from_list(lists:map(Fun, L))
  catch
    error:undef -> []
  end.

get_macros(Meta, Module, Ctx) ->
  ensure_loaded(Meta, Module, Ctx),
  try
    L = Module:'__info__'(macros),
    Fun = fun({F, A}) -> {F, A, 'normal'};
           ({_F, _A, _P} = FAP) -> FAP
          end,
    ordsets:from_list(lists:map(Fun, L))
 catch
   error:undef -> []
  end.

filter_exports(Exports, Args) ->
  ordsets:from_list(lists:foldl(fun filter_exports_by/2, Exports, Args)).
filter_exports_by({'only', Includes}, Exports) ->
  lists:filter(fun(FAP) ->
                   Match = lists:filter(fun(E) -> match_fa(E, FAP) end, Includes),
                   case Match of
                     [] -> false;
                     _ -> true
                   end
               end,
               Exports);
filter_exports_by({'exclude', Excludes}, Exports) ->
  lists:filter(fun(FAP)  ->
                   Match = lists:filter(fun(E) -> match_fa(E, FAP) end, Excludes),
                   case Match of
                     [] -> true;
                     _ -> false
                   end
               end,
               Exports);
filter_exports_by({'rename', Renames}, Exports) ->
  lists:foldl(fun({Fun, Arity, ParaType} = FAP, Acc) ->
                  New = lists:foldl(fun({Alias, {F, A}}, Acc0) ->
                                        case (F == Fun) andalso (A == Arity) of
                                          true -> [{Alias, {Fun, Arity, ParaType}} | Acc0];
                                          _ -> Acc0
                                        end;
                                       ({Alias, F}, Acc0) ->
                                        case (F == Fun) of
                                          true -> [{Alias, {Fun, Arity, ParaType}} | Acc0];
                                          _ -> Acc0
                                        end
                                    end,
                                    [],
                                    Renames),
                  case New of
                    [] -> [FAP | Acc];
                    _ -> New ++ [FAP | Acc]
                  end
              end,
              [],
              Exports);
filter_exports_by(_, Exports) ->
  Exports.

match_fa({F, A}, {Fun, Arity, _ParaType}) ->
  (F == Fun) andalso (A == Arity);
match_fa(Name, {Fun, _Arity, _ParaType}) when is_atom(Name) ->
  Name == Fun.

rewrite_function(Meta, Module, Fun, FunMeta, Arity, ParaType, Args) ->
  case kapok_rewrite:inline(Module, Fun, Arity, ParaType) of
    {M, F, _A, _P} ->
      Dot = {dot, FunMeta, {{identifier, FunMeta, M}, {identifier, FunMeta, F}}},
      Ast = {list, Meta, [Dot | Args]},
      {rewrite, Ast};
    false ->
      case kapok_rewrite:rewrite(Meta, Module, Fun, FunMeta, Arity, ParaType, Args) of
        false ->
          false;
        Ast ->
          {rewrite, Ast}
      end
  end.

%% ERROR HANDLING

format_error({ambiguous_call, {M, F, A, FAP1, FAP2}}) ->
  io_lib:format("find function ~ts:~ts/~B duplicates in ~p and ~p", [M, F, A, FAP1, FAP2]);
format_error({ambiguous_call, {F, A, FAP1, FAP2}}) ->
  io_lib:format("function ~ts/~B imported from both ~p and ~p, call in ambiguous",
                [F, A, FAP1, FAP2]).
