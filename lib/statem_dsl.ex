defmodule PropCheck.StateM.DSL do

  @moduledoc """
  This module provides a shallow DSL (domain specific langauge) in Elixir
  for property based testing of stateful systems.

  ## The basic approach
  Property based testing of stateful systems is different from ordinary property
  based testing and has two phases. In phase 1, the generators create a list of
  (symbolic) commands including their parameters to be run against the system under test
  (SUT). A state machine guides the generation of commands.

  In phase 2, the commands are executed and the state machine checks that  the
  SUT is in the same state as the state machine. If an invalid state is
  detected, then the command sequence is shrunk towards a shorter sequence
  serving then as counter examples.

  This appraoch works exactly the same as with `PropCheck.StateM` and
  `PropCheck.FSM`. The main difference is the API, grouping pre- and postconditions,
  state transitions and argument generators around the commands of the SUT. This
  leads towards more logical locality compared to the former implementations.
  Quickcheck EQC has a similar appraoch for structuring their modern state machines.

  ## The DSL

  A state machine acting as a model of the SUT can be defined by focussing on
  states or on transitions. We  focus here on the transitions. A transition is a
  command calling the SUT. Thefore the main phrase of the DSL is the `defcommand`
  macro.

      defcommand :find do
        # define the rules for executing the find command here
      end

  Inside the `command` macro, we define all the rules which the command must
  obey. As an example, we discuss here as an example the slightly simplified
  command `:find` from `test/cache_dsl_test.exs`. The SUT is a cache
  implementation based on an ETS and the model is is based on a list of
  (key/value)-pairs. This example is derived from [Fred Hebert's PropEr Testing,
  Chapter 9](http://propertesting.com/book_stateful_properties.html)

  The `find`-command is a call the `find/1` API function. Its arguments are
  generated by `key()`, which boils down to numeric values. The arguments for
  the command are defined by the function `args(state)` returning a fixed list
  of generators. In our example, the arguments do not depend on the model state.
  Next, we need to define the execution of the command by defining function
  `impl/n`. This function takes as many arguments as  `args/1` has elements in
  the argument list. The `impl`-function allows to apply conversion of
  parameters and return values to ease the testing. A typical example is the
  conversion of an `{:ok, value}` tuple to only `value` which can simplify
  working with `value`.

      defcommand :find do
        def impl(key), do: Cache.find(key)
        def args(_state), do: fixed_list([key()])
      end

  After defining how a command is executed, we need to define in which state
  this is allowed. For this, we define function `pre/2`, taking the model state
  and the generated list of arguments to check whether this call is
  allowed in the current model state. In this particular example, `find` is always
  allowed, hence we return true without any further checking. This also the
  default implementation and the reason why the precondition is missing
  in the test file.

      defcommand :find do
        def impl(key), do: Cache.find(key)
        def args(_state), do: fixed_list([key()])
        def pre(_state, [_key]}), do: true
      end

  If the precondition is satisfied, the call can happen. After the call, the SUT
  can be in a different state and the model state must be updated according to
  the mapping of the SUT to the model. Function `next/3` takes the state before
  the call, the list of rguments and the symbolic or dynamic result (depending
  on phase 1 or 2, respectively). `next/3` returns the  new model state.  Since
  searching for a key in the cache does not modify the system nor the model
  state, nothing is to do. This is again the default implementation and thus
  dismissed in the test file.

      defcommand :find do
        def impl(key), do: Cache.find(key)
        def args(_state), do: fixed_list([key()])
        def pre(_state, [_key]}), do: true
        def next(old_state, _args, call_result), do: state
      end

  The missing part of the command definition is the post condition, checking
  that after calling the system in phase 2 the system is in the expected state
  compared the model. This check is implemented in function `post/3`, which
  again has a trivial default implementation for post conditions that are always
  true. In this example, we check if the `call_result` is `{:error, :not_found}`
  we also do not find the key in our model list `entries`. The other case is
  that if we a return value of `{:ok, val}`, we then also find the value via
  the `key` in our list of `entries`.

      defcommand :find do
        def impl(key), do: Cache.find(key)
        def args(_state), do: fixed_list([key()])
        def pre(_state, [_key]}), do: true
        def next(old_state, _args, _call_result), do: state
        def post(entries, [key], call_result) do
          case List.keyfind(entries, key, 0, false) do
              false       -> call_result == {:error, :not_found}
              {^key, val} -> call_result == {:ok, val}
          end
        end
      end

  This completes the DSL for command definitions.

  ## Additional model elements

  In addition to commands, we need to define the model itself. This is the
  ingenious part of stateful property based testing! The initial state
  of the model must be implemented as function `initial_state/0`. From this
  function, all model evolutions start. In our simplified cache example the
  initial model is an empty list:

      def initial_state(), do: []

  The commands are generated with the same frequency by default. Often, this
  is not appropriate, e.g. in the cache example we expect many more `find` then
  `cache` commands. Therefore, commands can have a weight, which is technically used
  inside a `PropCheck.BasicTypes.frequency/1` generator. The weights are defined
  in function `weight/2`, taking the current model state and the command to be
  generated. The return value is an integer defining the frequency. In our cache
  example we want three times more `find` than other commands:

      def weight(_state, :find),  do: 1
      def weight(_state, :cache), do: 3
      def weight(_state, :flush), do: 1

  ## The property to test
  The property to test the stateful system is for all systems more or less
  equal. We generate all commands via generator `commands/1`, which takes
  a module with callbacks as parameter. Inside the test, we first start
  the SUT, execute the commands with `run_commands/1`, stopping the SUT
  and evaluating the result of the executions as a boolean expression.
  This boolean expression can be adorned with further functions and macros
  to analyze the generated commands (via `PropCheck.aggregate/2`) or to
  inspect the history if a failure occurs (via `PropCheck.when_fail/2`).
  In the test cases, you find more examples of such adornments.

      property "run the sequential cache", [:verbose] do
        forall cmds <- commands(__MODULE__) do
          Cache.start_link(@cache_size)
          execution = run_commands(cmds)
          Cache.stop()
          (execution.result == :ok)
        end
      end


  """

  use PropCheck
  require Logger

  @typedoc """
  The name of a command must be an atom.
  """
  @type command_name :: atom
  @typedoc """
  A symbolic state can be anything and appears only during phase 1.
  """
  @type symbolic_state :: any
  @typedoc """
  A dynamic state can be anything and appears only during phase 2.
  """
  @type dynamic_state :: any
  @typedoc """
  The combination of symbolic and dynamic states are required for functions
  which are used in both phases 1 and 2.
  """
  @type state_t :: symbolic_state | dynamic_state
  @typedoc """
  Each result of a symbolic call is stored in a symbolic variable. Their values
  are opaque and can only used as whole.
  """
  @type symbolic_var :: {:var, pos_integer}
  @typedoc """
  A symbolic call is the typical mfa-tuple plus the indicator `:call`.
  """
  @type symbolic_call :: {:call, module, atom, [any]}
  @typedoc """
  A value of type `command` denotes the execution of a symblic command and
  storing its result in a symbolic variable.
  """
  @type command :: {:set, symbolic_var, symbolic_call}
  @typedoc """
  The history of command execution in phase 2 is stored in a history element.
  It contains the current dynamic state and the call to be made.
  """
  @type history_element :: {dynamic_state, symbolic_call}
  @typedoc """
  The result of the command execution. It contains either the state of the failing
  precondition, the command's return value of the failing postcondition,
  the exception values or `:ok` if everything is fine.
  """
  @type result_t :: :ok | {:pre_condition, state_t} | {:post_condition, any} |
    {:exception, any}
  # the functional command generator type, which takes a state and creates
  # a data generator from it.
  @typep gen_fun_t :: (state_t -> PropCheck.BasicTypes.type)
  @typep cmd_t ::
      {:args, module, String.t, atom, gen_fun_t} # |
      # {:cmd, module, String.t, gen_fun_t}
  @typedoc """
  The combined result of the test. It contains the history of all executed commands,
  the final state and the final result. Everything is fine, if `result` is `:ok`.
  """
  @type t :: %__MODULE__{
    history: [history_element],
    state: state_t,
    result: result_t
  }
  defstruct [
    history: [],
    state: nil,
    result: :ok
  ]

  @doc """
  The initial state of the state machine is computed by this callback.
  """
  @callback initial_state() :: symbolic_state

  @doc """
  The optional weights for the command generation. It takes the current
  model state and returns a list of command/weight pairs. Commands,
  which are not allowed in a specific state, should be ommitted, since
  a frequency of `0` is not allowed. 

      def weight(state), do: [x: 1, y: 1, a: 2, b: 2]

  """
  @callback weight(symbolic_state, command_name) :: pos_integer
  @optional_callbacks weight: 2


  defmacro __using__(_options) do
    quote do
      import unquote(__MODULE__)
      Module.register_attribute __MODULE__, :commands, accumulate: true
      @before_compile unquote(__MODULE__)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __all_commands__(), do: @commands
    end
  end

  @known_suffixes [:pre, :post, :args, :next]
  @doc """
  Defines a new command of the model. Inside the command, local functions
  define
  * how the command is executed (`impl(...)`)
  * how the arguments in the current model state are generated (`args(state)`
  * if the command is allowed in the current model state (`pre(state, arg_list) :: bolean`)
  * what the next state of the model is after the call (`next(old_state, arg_list, result) :: new_state`)
  * if the system under test is in the correct state after the call
    (`post(old_state, arg_list, result) :: boolean`)
  """
  defmacro defcommand(name, do: block) do
    pre  = String.to_atom("#{name}_pre")
    next = String.to_atom("#{name}_next")
    post = String.to_atom("#{name}_post")
    args = String.to_atom("#{name}_args")
    quote do
      def unquote(pre)(_state, _call), do: true
      def unquote(next)(state, _call, _result), do: state
      def unquote(post)(_state, _call, _res), do: true
      def unquote(args)(_state), do: fixed_list([])
      defoverridable [{unquote(pre), 2}, {unquote(next), 3},
        {unquote(post), 3}, {unquote(args), 1}]
      @commands Atom.to_string(unquote(name))
      unquote(Macro.postwalk(block, &rename_def_in_command(&1, name)))
    end
  end

  defp rename_def_in_command({:def, c1, [{:impl, c2, impl_args}, impl_body]}, name) do
      # Logger.error "Found impl with body #{inspect impl_body}"
    {:def, c1, [{name, c2, impl_args}, impl_body]}
  end
  defp rename_def_in_command({:def, c1, [{suffix_name, c2, args}, body]}, name)
    when suffix_name in @known_suffixes
    do
      new_name = String.to_atom("#{name}_#{suffix_name}")
      # Logger.error "Found suffix: #{new_name}"
      {:def, c1,[{new_name, c2, args}, body]}
    end
  defp rename_def_in_command(ast, _name) do
    # Logger.warn "Found ast = #{inspect ast}"
    ast
  end

  @doc """
  Generates the command list for the given module
  """
  @spec commands(module) :: :proper_types.type()
  def commands(mod) do
    cmd_list = command_list(mod, "")
    # Logger.debug "commands:  cmd_list = #{inspect cmd_list}"
    gen_commands(mod, cmd_list)
  end

  @spec gen_commands(module, [cmd_t]) :: :proper_types.type()
  defp gen_commands(mod, cmd_list) do
    initial_state = mod.initial_state()
    gen_cmd = sized(size, gen_cmd_list(size, cmd_list, mod, initial_state, 1))
    such_that cmds <- gen_cmd, when: is_valid(mod, initial_state, cmds)
  end

  # TODO: How is this function to be defined?
  defp is_valid(_mod, _initial_state, _cmds) do
    true
  end

  # The internally used recursive generator for the command list
  @spec gen_cmd_list(pos_integer, [cmd_t], module, state_t, pos_integer) :: PropCheck.BasicTypes.type
  defp gen_cmd_list(0, _cmd_list, _mod, _state, _step_counter), do: exactly([])
  defp gen_cmd_list(size, cmd_list, mod, state, step_counter) do
    # Logger.debug "gen_cmd_list: cmd_list = #{inspect cmd_list}"
    cmds_with_args = cmd_list
    |> Enum.map(fn {:cmd, _mod, _f, arg_fun} -> arg_fun.(state) end)
    # |> fn l ->
    #   Logger.debug("gen_cmd_list: call list is #{inspect l}")
    #   l end.()
    cmds = if :erlang.function_exported(mod, :weight, 1) do
      freq_cmds(cmds_with_args, state, mod)
    else
      oneof(cmds_with_args)
    end

    let call <-
      (such_that c <- cmds, when: check_precondition(state, c))
      do
        gen_result = {:var, step_counter}
        gen_state = call_next_state(state, call, gen_result)
        let cmds <- gen_cmd_list(size - 1, cmd_list, mod, gen_state, step_counter + 1) do
          [{state, {:set, gen_result, call}} | cmds]
        end
      end
  end

  # takes the list of weighted commands and filters
  # those from `cmd_list´ which have weights attached.
  defp freq_cmds(cmd_list, state, mod) do
    w_cmds = mod.weight(state)
    w_cmds
    |> Enum.map(fn {f, w} ->
      {w, find_call(cmd_list, f)}
    end)
    |> frequency()
  end

  defp find_call(cmd_list, fun) do
    Enum.find(cmd_list, fn {:call, _m, f, _a} ->
      f == fun end)
  end

  @doc """
  Runs the list of generated commands according to the model.

  Returns the result, the history and the final state of the model.
  """
  @spec run_commands([command]) :: t
  def run_commands(commands) do
    commands
    |> Enum.reduce(%__MODULE__{}, fn
      # do nothing if a failure occured
      _cmd, acc = %__MODULE__{result: {r, _} } when r != :ok -> acc
      # execute the next command
      cmd, acc ->
        cmd
        |> execute_cmd()
        |> update_history(acc)
    end)
  end

  @spec execute_cmd({state_t, command}) :: {state_t, symbolic_call, result_t}
  defp execute_cmd({state, {:set, {:var, _}, c = {:call, m, f, args}}}) do
    result = if check_precondition(state, c) do
      try do
        result = apply(m, f, args)
        if check_postcondition(state, c, result) do
          {:ok, result}
        else
          {:post_condition, result}
        end
      rescue exc -> {:exception, exc}
      catch
        value -> {:exception, value}
        kind, value -> {:exception, {kind, value}}
      end
    else
      {:pre_condition, state}
    end
    {state, c, result}
  end

  defp update_history(event = {s, _, r}, %__MODULE__{history: h}) do
    result_value = case r do
      {:ok, _} -> :ok
      _ -> r
    end
    %__MODULE__{state: s, result: result_value, history: [event | h]}
  end

  @spec call_next_state(state_t, symbolic_call, any) :: state_t
  defp call_next_state(state, {:call, mod, f, args}, result) do
    next_fun = (Atom.to_string(f) <> "_next")
      |> String.to_atom
    apply(mod, next_fun, [state, args, result])
  end

  @spec check_precondition(state_t, symbolic_call) :: boolean
  defp check_precondition(state, {:call, mod, f, args}) do
    pre_fun = (Atom.to_string(f) <> "_pre") |> String.to_atom
    apply(mod, pre_fun, [state, args])
  end

  @spec check_postcondition(state_t, symbolic_call, any) :: any
  defp check_postcondition(state,  {:call, mod, f, args}, result) do
    post_fun = (Atom.to_string(f) <> "_post") |> String.to_atom
    apply(mod, post_fun, [state, args, result])
  end

  @doc """
  Takes a list of generated commands and returns a list of
  mfa-tuples. This can be used for aggregation of commands.
  """
  @spec command_names(cmds :: [command]) :: [mfa]
  def command_names(cmds) do
    cmds
    |> Enum.map(fn {_state, {:set, _var, {:call, m, f, args}}} ->
      # "#{m}.#{f}/#{length(args)}"
      {m, f, length(args)}
    end)
  end


  # Detects alls commands within `mod_bin_code`, i.e. all functions with the
  # same prefix and a suffix `_command` or `_args` and a prefix `_next`.
  @spec command_list(module, binary) :: [{:cmd, module, String.t, (state_t -> symbolic_call)}]
  defp command_list(mod, "") do
    mod
    |> find_commands()
    |> Enum.map(fn {cmd, _arity} ->
      args_fun = fn state -> apply(mod, String.to_atom(cmd <> "_args"), [state]) end
      args = gen_call(mod, String.to_atom(cmd), args_fun)
      {:cmd, mod, cmd, args}
    end)
  end
  # defp command_list(mod, mod_bin_code) do
  #   {^mod, all_funs} = all_functions(mod_bin_code)
  #   cmd_impls = find_commands(mod_bin_code)
  #
  #   cmd_impls
  #   |> Enum.map(fn {cmd, _arity} ->
  #     if find_fun(all_funs, "_args", [1]) do
  #       args_fun = fn state -> apply(mod, String.to_atom(cmd <> "_args"), [state]) end
  #       args = gen_call(mod, String.to_atom(cmd), args_fun)
  #       {:cmd, mod, cmd, args}
  #     else
  #       {:cmd, mod, cmd, & apply(mod, String.to_atom(cmd <> "_command"), &1)}
  #     end
  #   end)
  # end

  # Generates a function, which expects a state to create the call tuple
  # with constants for module and function and an argument generator.
  defp gen_call(mod, fun, arg_fun) when is_atom(fun) and is_function(arg_fun, 1) do
    fn state ->  {:call, mod, fun, arg_fun.(state)} end
  end


  # @spec find_fun([{String.t, arity}], String.t, [arity]) :: boolean
  # defp find_fun(all, suffix, arities) do
  #   all
  #   |> Enum.find_index(fn {f, a} ->
  #     a in arities and String.ends_with?(f, suffix)
  #   end)
  #   |> is_integer()
  # end

  @spec find_commands(binary|module) :: [{String.t, arity}]
  defp find_commands(mod) when is_atom(mod), do:
    mod.__all_commands__() |> Enum.map(& ({&1, 0}))
  # defp find_commands(mod_bin_code) do
  #   {_mod, funs} = all_functions(mod_bin_code)
  #
  #   next_funs = funs
  #   |> Stream.filter(fn {f, a} ->
  #     String.ends_with?(f, "_next") and (a in [3,4]) end)
  #   |> Stream.map(fn {f, _a} -> String.replace_suffix(f, "_next", "") end)
  #   |> MapSet.new()
  #
  #   funs
  #   |> Enum.filter(fn {f, _a} ->
  #     MapSet.member?(next_funs, f)
  #   end)
  # end

  # @spec all_functions(binary) :: {module, [{String.t, arity}]}
  # defp all_functions(mod_bin_code) do
  #   {:ok, {mod, [{:exports, functions}]}} = :beam_lib.chunks(mod_bin_code, [:exports])
  #   funs = Enum.map(functions, fn {f, a} -> {Atom.to_string(f), a} end)
  #   {mod, funs}
  # end

end
