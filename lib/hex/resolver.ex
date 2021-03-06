defmodule Hex.Resolver do
  alias Hex.Registry
  import Hex.Mix
  require Record

  Record.defrecordp :info, [:deps, :top_level, :state, :backtrack]
  Record.defrecordp :state, [:activated, :pending, :optional, :deps]
  Record.defrecordp :request, [:app, :name, :req, :parent]
  Record.defrecordp :active, [:app, :name, :version, :state, :parents, :possibles]
  Record.defrecordp :parent, [:name, :version, :requirement]

  def resolve(requests, deps, locked) do
    {:ok, state}     = Agent.start_link(fn -> new_set() end)
    {:ok, backtrack} = Agent.start_link(fn -> [] end)

    try do
      top_level = top_level(deps)
      info = info(deps: deps, top_level: top_level, state: state, backtrack: backtrack)

      optional =
        Enum.into(locked, %{}, fn {name, app, version} ->
          {:ok, req} = Version.parse_requirement(version)
          parent     = parent(name: "mix.lock", requirement: req)
          request    = request(app: app, name: name, req: req, parent: parent)
          {name, [request]}
        end)

      pending =
        Enum.map(requests, fn {name, app, req, from} ->
          req    = compile_requirement(req, name)
          parent = parent(name: from, requirement: req)
          request(name: name, app: app, req: req, parent: parent)
        end)
        |> Enum.uniq

      if activated = do_resolve(pending, optional, info, %{}) do
        {:ok, activated}
      else
        {:error, error_message(backtrack)}
      end
    after
      Agent.stop(backtrack)
      Agent.stop(state)
    end
  end

  defp do_resolve([], _optional, _info, activated) do
    Enum.map(activated, fn {name, active(app: app, version: version)} ->
      {name, app, version}
    end) |> Enum.reverse
  end

  defp do_resolve([request(name: name, req: req, parent: parent) = request|pending], optional, info, activated) do
    case activated[name] do
      active(version: version, possibles: possibles, parents: parents) = active ->
        possibles = Enum.filter(possibles, &version_match?(&1, req))
        parents   = [parent|parents]
        active    = active(active, possibles: possibles, parents: parents)

        if version_match?(version, req) do
          activated = Map.put(activated, name, active)
          do_resolve(pending, optional, info, activated)
        else
          add_backtrack_info(name, version, parents, info)
          backtrack(active, info, activated)
        end

      nil ->
        {opts, optional} = Map.pop(optional, name)
        opts             = opts || []
        requests         = [request|opts]
        parents          = Enum.map(requests, &request(&1, :parent))

        case get_versions(name, requests) do
          {:ok, versions} ->
            activate(request, pending, versions, optional, info, activated, parents)

          {:error, _requests} ->
            add_backtrack_info(name, nil, parents, info)
            backtrack(activated[parent(parent, :name)], info, activated)
        end
    end
  end

  defp backtrack(nil, _info, _activated) do
    nil
  end

  defp backtrack(active(app: app, name: name, possibles: possibles, parents: parents, state: state) = active, info, activated) do
    case possibles do
      [] ->
        Enum.find_value(parents, fn parent(name: name) ->
          backtrack(activated[name], info, activated)
        end)

      [version|possibles] ->
        state(activated: activated, pending: pending, optional: optional, deps: deps) = state

        active = active(active, possibles: possibles, version: version)
        info = info(info, deps: deps)
        {new_pending, new_optional, new_deps} = get_deps(app, name, version, info, activated)
        pending = pending ++ new_pending
        optional = merge_optional(optional, new_optional)
        info = info(info, deps: new_deps)

        activated = Map.put(activated, name, active)
        do_resolve(pending, optional, info, activated)
    end
  end

  defp activate(request(app: app, name: name), pending, [version|possibles],
                optional, info(deps: deps) = info, activated, parents) do
    {new_pending, new_optional, new_deps} = get_deps(app, name, version, info, activated)
    new_pending = pending ++ new_pending
    new_optional = merge_optional(optional, new_optional)

    state = state(activated: activated, pending: pending, optional: optional, deps: deps)

    if track_state(state, info) do
      new_active = active(app: app, name: name, version: version, state: state,
                          possibles: possibles, parents: parents)
      activated = Map.put(activated, name, new_active)

      info = info(info, deps: new_deps)

      do_resolve(new_pending, new_optional, info, activated)
    end
  end

  defp get_versions(package, requests) do
    if versions = Registry.get_versions(package) do
      try do
        {versions, _requests} =
          Enum.reduce(requests, {versions, []}, fn request, {versions, requests} ->
            req = request(request, :req)
            versions = Enum.filter(versions, &version_match?(&1, req))
            if versions == [] do
              throw [request|requests]
            else
              {versions, [request|requests]}
            end
          end)

        {:ok, Enum.reverse(versions)}
      catch
        :throw, requests ->
          {:error, requests}
      end

    else
      Mix.raise "Unable to find package #{package} in registry"
    end
  end

  defp get_deps(app, package, version, info(top_level: top_level, deps: all_deps), activated) do
    if deps = Registry.get_deps(package, version) do
      all_deps = attach_dep_and_children(all_deps, app, deps)

      upper_breadths = down_to(top_level, all_deps, String.to_atom(app))

      {reqs, opts} =
        Enum.reduce(deps, {[], []}, fn {name, app, req, optional}, {reqs, opts} ->
          req = compile_requirement(req, name)
          parent = parent(name: package, version: version, requirement: req)
          request = request(app: app, name: name, req: req, parent: parent)

          cond do
            was_overridden?(upper_breadths, String.to_atom(app)) ->
              {reqs, opts}
            optional && !activated[name] ->
              {reqs, [request|opts]}
            true ->
              {[request|reqs], opts}
          end
        end)

      {Enum.reverse(reqs), Enum.reverse(opts), all_deps}
    else
      Mix.raise "Unable to find package version #{package} v#{version} in registry"
    end
  end

  # Add a potentially new dependency and its children.
  # This function is used to add Hex packages to the dependency tree which
  # we use in down_to to check overridden status.
  defp attach_dep_and_children(deps, app, children) do
    app = String.to_atom(app)
    dep = Enum.find(deps, &(&1.app == app))

    children =
      Enum.map(children, fn {name, app, _req, _optional} ->
        app = String.to_atom(app)
        name = String.to_atom(name)
        %Mix.Dep{app: app, opts: [hex: name]}
      end)

    new_dep = put_in(dep.deps, children)

    put_dep(deps, new_dep) ++ children
  end

  # Replace a dependency in the tree
  defp put_dep(deps, new_dep) do
    Enum.reduce(deps, [], fn dep, deps ->
      if dep.app == new_dep.app do
        [new_dep|deps]
      else
        [dep|deps]
      end
    end)
    |> Enum.reverse
  end

  defp merge_optional(optional, new_optional) do
    new_optional =
      Enum.into(new_optional, %{}, fn request(name: name) = request ->
        {name, [request]}
      end)
    Map.merge(optional, new_optional, fn _, v1, v2 -> v1 ++ v2 end)
  end

  defp track_state(state(activated: activated), info(state: agent)) do
    activated = Enum.map(activated, fn {_, active} ->
      active(active, state: nil)
    end)

    Agent.get_and_update(agent, fn set ->
      {not Set.member?(set, activated), Set.put(set, activated)}
    end)
  end

  defp compile_requirement(nil, _package) do
    nil
  end

  defp compile_requirement(req, package) when is_binary(req) do
    case Version.parse_requirement(req) do
      {:ok, req} ->
        req
      :error ->
        Mix.raise "Invalid requirement #{inspect req} defined for package #{package}"
    end
  end

  defp compile_requirement(req, package) do
    Mix.raise "Invalid requirement #{inspect req} defined for package #{package}"
  end

  # TODO: Duplicate backtracks are pruned but we can also merge backtracks
  #       where the message only differs in a single version. This is often
  #       the case because many times packages don't change requirements
  #       between releases causing them to generate a message only differing
  #       in the package version. These messages should be rolled up into a
  #       single message.
  defp error_message(agent_pid) do
    backtrack_info = Agent.get(agent_pid, & &1)
    backtrack_info = prune_duplicate_backtracks(backtrack_info)
    messages =
      backtrack_info
      |> Enum.map(fn {name, version, parents} -> {name, version, Enum.sort(parents, &sort_parents/2)} end)
      |> Enum.sort()
      |> Enum.map(&backtrack_message/1)
    Enum.join(messages, "\n\n") <> "\n"
  end

  defp add_backtrack_info(name, version, parents, info(backtrack: agent)) do
    info = {name, version, parents}
    Agent.cast(agent, &[info|&1])
  end

  defp prune_duplicate_backtracks(backtracks) do
    backtracks = Enum.into(backtracks, new_set(), fn {name, version, parents} ->
      {name, version, new_set(parents)}
    end)

    Enum.reduce(backtracks, backtracks, fn {name1, version1, parents1}=item, backtracks ->
      count = Enum.count(backtracks, fn {name2, version2, parents2} ->
        name1 == name2 and version1 == version2 and Set.subset?(parents1, parents2)
      end)
      # We will always match ourselves once
      if count > 1 do
        Set.delete(backtracks, item)
      else
        backtracks
      end
    end)
  end

  # TODO: Handle sorting of mix.exs from umbrellas
  defp sort_parents(parent(name: "mix.exs"), _),  do: true
  defp sort_parents(_, parent(name: "mix.exs")),  do: false
  defp sort_parents(parent(name: "mix.lock"), _), do: true
  defp sort_parents(_, parent(name: "mix.lock")), do: false
  defp sort_parents(parent1, parent2),            do: parent1 <= parent2

  defp backtrack_message({name, version, parents}) do
    [ "Looking up alternatives for conflicting requirements on #{name}",
      if(version, do: "  Activated version: #{version}"),
      "  " <> Enum.map_join(parents, "\n  ", &parent_message/1)]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp parent_message(parent(name: path, version: nil, requirement: req)),
    do: "From #{path}: #{requirement(req)}"
  defp parent_message(parent(name: parent, version: version, requirement: req)),
    do: "From #{parent} v#{version}: #{requirement(req)}"

  defp requirement(nil), do: ">= 0.0.0"
  defp requirement(req), do: req.source

  defp new_set, do: new_set([])

  if Version.compare("1.2.0", System.version) == :gt do
    defp new_set(enum), do: Enum.into(enum, HashSet.new)
  else
    defp new_set(enum), do: Enum.into(enum, MapSet.new)
  end
end
