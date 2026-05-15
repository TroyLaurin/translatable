defmodule Translatable.Bundle do
  @moduledoc """
  Bundle output configuration shared by extract and package workflows.

  Bundles decide how Translatable artifacts are split across files. They are
  configured on a `Translatable.Runtime` backend and consumed by the workflow
  tasks:

    * `mix translatable.extract` writes committed source shards and build-only
      full extract shards.
    * `mix translatable.package` writes committed runtime shards and lock
      shards.
    * `mix translatable.validate` and `mix translatable.defer` use the same
      shard plan to compare artifacts consistently.

  Bundle strategies are deliberately about files, not message identity. Message
  keys are still derived from application, module, and message name.

  ## Strategies

  `everything/1` writes a single file per artifact type:

      bundle_everything filename: "my_app"

  `per_module/1` writes one shard per message module under a directory and also
  writes a `manifest.json` listing the shards:

      bundle_per_module path: "my_app"

  `custom/2` writes named shards based on explicit routing rules:

      bundle_custom path: "my_app" do
        default filename: "my_app.json"
        bundle filename: "web.json", includes: submodules(of: MyAppWeb)
      end

  For custom bundles, a default rule is required and receives every module that
  no explicit rule matches. If multiple explicit rules match, the most specific
  matcher wins. Equal specificity is an error, as are duplicate filenames.

  ## Runtime manifests

  Directory-based strategies write a runtime `manifest.json`. The JSON provider
  reads this manifest in releases so it can load exact files without scanning
  source modules or calling Mix.
  """

  defmodule SourceShard do
    @moduledoc false
    @enforce_keys [:id, :modules, :manifest_path, :extract_path, :metadata]
    defstruct [:id, :modules, :manifest_path, :extract_path, :metadata]

    @typedoc false
    @type t() :: %__MODULE__{
            id: String.t(),
            modules: [module()],
            manifest_path: Path.t(),
            extract_path: Path.t(),
            metadata: map()
          }
  end

  defmodule RuntimeShard do
    @moduledoc false
    @enforce_keys [:id, :modules, :lock_path, :runtime_path, :metadata]
    defstruct [:id, :modules, :lock_path, :runtime_path, :metadata]

    @typedoc false
    @type t() :: %__MODULE__{
            id: String.t(),
            modules: [module()],
            lock_path: Path.t(),
            runtime_path: Path.t(),
            metadata: map()
          }
  end

  defmodule Matcher.Submodules do
    @moduledoc false
    @enforce_keys [:module, :score]
    defstruct [:module, :score]

    @typedoc false
    @type t() :: %__MODULE__{module: module(), score: pos_integer()}
  end

  defmodule Matcher.Exact do
    @moduledoc false
    @enforce_keys [:module, :score]
    defstruct [:module, :score]

    @typedoc false
    @type t() :: %__MODULE__{module: module(), score: pos_integer()}
  end

  defmodule CustomRule do
    @moduledoc false
    @enforce_keys [:filename, :includes, :default?]
    defstruct [:filename, :includes, :default?]

    @typedoc false
    @type t() :: %__MODULE__{
            filename: String.t(),
            includes: [Matcher.Submodules.t() | Matcher.Exact.t()],
            default?: boolean()
          }
  end

  @enforce_keys [:strategy, :path]
  defstruct [:strategy, :path, :filename, rules: []]

  @type strategy() :: :everything | :per_module | :custom

  @type t() :: %__MODULE__{
          strategy: strategy(),
          path: Path.t(),
          filename: String.t() | nil,
          rules: [term()]
        }

  @spec everything(keyword()) :: t()
  def everything(opts) when is_list(opts) do
    filename = Keyword.fetch!(opts, :filename)
    path = Keyword.get(opts, :path, "")

    %__MODULE__{
      strategy: :everything,
      filename: filename,
      path: path
    }
  end

  @spec per_module(keyword()) :: t()
  def per_module(opts) when is_list(opts) do
    path = Keyword.fetch!(opts, :path)

    %__MODULE__{
      strategy: :per_module,
      filename: nil,
      path: path
    }
  end

  @spec custom(keyword(), [term()]) :: t()
  def custom(opts, rules) when is_list(opts) and is_list(rules) do
    path = Keyword.get(opts, :path, "")
    validate_custom_rules!(rules)

    %__MODULE__{
      strategy: :custom,
      filename: nil,
      path: path,
      rules: rules
    }
  end

  @spec default(keyword()) :: term()
  def default(opts) when is_list(opts) do
    %CustomRule{
      filename: normalize_json_filename(Keyword.fetch!(opts, :filename)),
      includes: [],
      default?: true
    }
  end

  @spec bundle(keyword()) :: term()
  def bundle(opts) when is_list(opts) do
    includes = opts |> Keyword.fetch!(:includes) |> List.wrap()

    %CustomRule{
      filename: normalize_json_filename(Keyword.fetch!(opts, :filename)),
      includes: includes,
      default?: false
    }
  end

  @spec submodules(keyword()) :: term()
  def submodules(of: module) when is_atom(module) do
    %Matcher.Submodules{module: module, score: module_score(module)}
  end

  @doc false
  @spec source_shards(t(), [module()], keyword()) :: [SourceShard.t()]
  def source_shards(bundle, modules, opts \\ [])

  def source_shards(%__MODULE__{strategy: :everything} = bundle, modules, opts) do
    [
      %SourceShard{
        id: shard_id(bundle),
        modules: Enum.sort_by(modules, &module_name/1),
        manifest_path: manifest_path(bundle),
        extract_path: extract_path(bundle, opts),
        metadata: bundle_metadata(bundle)
      }
    ]
  end

  def source_shards(%__MODULE__{strategy: :per_module, path: path} = bundle, modules, opts) do
    modules
    |> Enum.sort_by(&module_name/1)
    |> Enum.map(fn module ->
      module_name = module_name(module)
      filename = "#{module_name}.json"

      %SourceShard{
        id: Path.join(path, module_name),
        modules: [module],
        manifest_path: Path.join(["priv", "translatable", "source", path, filename]),
        extract_path: Path.join([build_path(opts), "translatable", "extract", path, filename]),
        metadata: Map.put(bundle_metadata(bundle), "module", module_name)
      }
    end)
  end

  def source_shards(%__MODULE__{strategy: :custom} = bundle, modules, opts) do
    bundle
    |> custom_module_groups(modules)
    |> Enum.map(fn {rule, grouped_modules} ->
      source_custom_shard(bundle, rule, grouped_modules, opts)
    end)
  end

  @doc false
  @spec runtime_shards(t(), [module()]) :: [RuntimeShard.t()]
  def runtime_shards(%__MODULE__{strategy: :everything} = bundle, modules) do
    [
      %RuntimeShard{
        id: shard_id(bundle),
        modules: Enum.sort_by(modules, &module_name/1),
        lock_path: lock_path(bundle),
        runtime_path: runtime_path(bundle),
        metadata: bundle_metadata(bundle)
      }
    ]
  end

  def runtime_shards(%__MODULE__{strategy: :per_module, path: path} = bundle, modules) do
    modules
    |> Enum.sort_by(&module_name/1)
    |> Enum.map(fn module ->
      module_name = module_name(module)
      filename = "#{module_name}.json"

      %RuntimeShard{
        id: Path.join(path, module_name),
        modules: [module],
        lock_path: Path.join(["priv", "translatable", "lock", path, filename]),
        runtime_path: Path.join(["priv", "translatable", "runtime", path, filename]),
        metadata: Map.put(bundle_metadata(bundle), "module", module_name)
      }
    end)
  end

  def runtime_shards(%__MODULE__{strategy: :custom} = bundle, modules) do
    bundle
    |> custom_module_groups(modules)
    |> Enum.map(fn {rule, grouped_modules} ->
      runtime_custom_shard(bundle, rule, grouped_modules)
    end)
  end

  @spec source_manifest_path(t()) :: Path.t() | nil
  def source_manifest_path(%__MODULE__{strategy: :everything}), do: nil

  def source_manifest_path(%__MODULE__{strategy: :per_module, path: path}),
    do: Path.join(["priv", "translatable", "source", path, "manifest.json"])

  def source_manifest_path(%__MODULE__{strategy: :custom, path: path}),
    do: Path.join(["priv", "translatable", "source", path, "manifest.json"])

  @spec extract_manifest_path(t(), keyword()) :: Path.t() | nil
  def extract_manifest_path(bundle, opts \\ [])

  def extract_manifest_path(%__MODULE__{strategy: :everything}, _opts), do: nil

  def extract_manifest_path(%__MODULE__{strategy: :per_module, path: path}, opts),
    do: Path.join([build_path(opts), "translatable", "extract", path, "manifest.json"])

  def extract_manifest_path(%__MODULE__{strategy: :custom, path: path}, opts),
    do: Path.join([build_path(opts), "translatable", "extract", path, "manifest.json"])

  @spec lock_manifest_path(t()) :: Path.t() | nil
  def lock_manifest_path(%__MODULE__{strategy: :everything}), do: nil

  def lock_manifest_path(%__MODULE__{strategy: :per_module, path: path}),
    do: Path.join(["priv", "translatable", "lock", path, "manifest.json"])

  def lock_manifest_path(%__MODULE__{strategy: :custom, path: path}),
    do: Path.join(["priv", "translatable", "lock", path, "manifest.json"])

  @spec runtime_manifest_path(t()) :: Path.t() | nil
  def runtime_manifest_path(%__MODULE__{strategy: :everything}), do: nil

  def runtime_manifest_path(%__MODULE__{strategy: :per_module, path: path}),
    do: Path.join(["priv", "translatable", "runtime", path, "manifest.json"])

  def runtime_manifest_path(%__MODULE__{strategy: :custom, path: path}),
    do: Path.join(["priv", "translatable", "runtime", path, "manifest.json"])

  @spec extract_path(t(), keyword()) :: Path.t()
  def extract_path(%__MODULE__{strategy: :everything, filename: filename, path: path}, opts \\ []) do
    Path.join([build_path(opts), "translatable", "extract", path, "#{filename}.json"])
  end

  @spec lock_path(t()) :: Path.t()
  def lock_path(%__MODULE__{strategy: :everything, filename: filename, path: path}) do
    Path.join(["priv", "translatable", "lock", path, "#{filename}.json"])
  end

  @spec manifest_path(t()) :: Path.t()
  def manifest_path(%__MODULE__{strategy: :everything, filename: filename, path: path}) do
    Path.join(["priv", "translatable", "source", path, "#{filename}.json"])
  end

  @spec runtime_path(t()) :: Path.t()
  def runtime_path(%__MODULE__{strategy: :everything, filename: filename, path: path}) do
    Path.join(["priv", "translatable", "runtime", path, "#{filename}.json"])
  end

  @spec runtime_files(t()) :: {:ok, [Path.t()]} | {:error, term()}
  def runtime_files(%__MODULE__{strategy: :everything} = bundle),
    do: {:ok, [runtime_path(bundle)]}

  def runtime_files(%__MODULE__{strategy: strategy} = bundle)
      when strategy in [:per_module, :custom] do
    manifest_path = runtime_manifest_path(bundle)

    with {:ok, body} <- File.read(manifest_path),
         {:ok, %{"shards" => shards}} when is_list(shards) <- Jason.decode(body) do
      files =
        Enum.flat_map(shards, fn
          %{"runtime_path" => path} when is_binary(path) ->
            [Path.expand(path, Path.dirname(manifest_path))]

          _shard ->
            []
        end)

      {:ok, files}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_runtime_manifest}
    end
  end

  @doc false
  @spec write_source_manifests!(t(), [SourceShard.t()]) :: :ok
  def write_source_manifests!(%__MODULE__{strategy: :everything}, _shards), do: :ok

  def write_source_manifests!(%__MODULE__{strategy: strategy} = bundle, shards)
      when strategy in [:per_module, :custom] do
    write_bundle_manifest!(
      source_manifest_path(bundle),
      "translatable.source-bundles.v1",
      shards,
      fn shard ->
        %{
          "id" => shard.id,
          "modules" => Enum.map(shard.modules, &module_name/1),
          "source_path" => Path.basename(shard.manifest_path),
          "bundle" => shard.metadata
        }
      end
    )
  end

  @doc false
  @spec write_extract_manifests!(t(), [SourceShard.t()], keyword()) :: :ok
  def write_extract_manifests!(bundle, shards, opts \\ [])

  def write_extract_manifests!(%__MODULE__{strategy: :everything}, _shards, _opts), do: :ok

  def write_extract_manifests!(%__MODULE__{strategy: strategy} = bundle, shards, opts)
      when strategy in [:per_module, :custom] do
    write_bundle_manifest!(
      extract_manifest_path(bundle, opts),
      "translatable.extract-bundles.v1",
      shards,
      fn shard ->
        %{
          "id" => shard.id,
          "modules" => Enum.map(shard.modules, &module_name/1),
          "extract_path" => Path.basename(shard.extract_path),
          "bundle" => shard.metadata
        }
      end
    )
  end

  @doc false
  @spec write_lock_manifests!(t(), [RuntimeShard.t()]) :: :ok
  def write_lock_manifests!(%__MODULE__{strategy: :everything}, _shards), do: :ok

  def write_lock_manifests!(%__MODULE__{strategy: strategy} = bundle, shards)
      when strategy in [:per_module, :custom] do
    write_bundle_manifest!(
      lock_manifest_path(bundle),
      "translatable.lock-bundles.v1",
      shards,
      fn shard ->
        %{
          "id" => shard.id,
          "modules" => Enum.map(shard.modules, &module_name/1),
          "lock_path" => Path.basename(shard.lock_path),
          "bundle" => shard.metadata
        }
      end
    )
  end

  @doc false
  @spec write_runtime_manifests!(t(), [RuntimeShard.t()]) :: :ok
  def write_runtime_manifests!(%__MODULE__{strategy: :everything}, _shards), do: :ok

  def write_runtime_manifests!(%__MODULE__{strategy: strategy} = bundle, shards)
      when strategy in [:per_module, :custom] do
    write_bundle_manifest!(
      runtime_manifest_path(bundle),
      "translatable.runtime-bundles.v1",
      shards,
      fn shard ->
        %{
          "id" => shard.id,
          "modules" => Enum.map(shard.modules, &module_name/1),
          "runtime_path" => Path.basename(shard.runtime_path),
          "bundle" => shard.metadata
        }
      end
    )
  end

  defp write_bundle_manifest!(path, format, shards, shard_to_json) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    data = %{
      "format" => format,
      "shards" => Enum.map(shards, shard_to_json)
    }

    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end

  defp source_custom_shard(%__MODULE__{path: path} = bundle, rule, modules, opts) do
    %SourceShard{
      id: custom_shard_id(path, rule.filename),
      modules: Enum.sort_by(modules, &module_name/1),
      manifest_path: Path.join(["priv", "translatable", "source", path, rule.filename]),
      extract_path: Path.join([build_path(opts), "translatable", "extract", path, rule.filename]),
      metadata: custom_bundle_metadata(bundle, rule)
    }
  end

  defp runtime_custom_shard(%__MODULE__{path: path} = bundle, rule, modules) do
    %RuntimeShard{
      id: custom_shard_id(path, rule.filename),
      modules: Enum.sort_by(modules, &module_name/1),
      lock_path: Path.join(["priv", "translatable", "lock", path, rule.filename]),
      runtime_path: Path.join(["priv", "translatable", "runtime", path, rule.filename]),
      metadata: custom_bundle_metadata(bundle, rule)
    }
  end

  defp custom_module_groups(%__MODULE__{rules: rules}, modules) do
    assignments =
      Enum.map(modules, fn module -> {module, custom_rule_for_module!(rules, module)} end)

    rules
    |> Enum.map(fn rule ->
      grouped_modules =
        assignments
        |> Enum.filter(fn {_module, assigned_rule} -> assigned_rule == rule end)
        |> Enum.map(fn {module, _rule} -> module end)

      {rule, grouped_modules}
    end)
    |> Enum.reject(fn {_rule, modules} -> modules == [] end)
  end

  defp custom_rule_for_module!(rules, module) do
    default = Enum.find(rules, & &1.default?)

    matches =
      rules
      |> Enum.reject(& &1.default?)
      |> Enum.flat_map(fn rule ->
        rule.includes
        |> Enum.flat_map(fn matcher ->
          case matcher_score(matcher, module) do
            nil -> []
            score -> [{rule, matcher, score}]
          end
        end)
      end)

    case best_custom_matches(matches) do
      [] ->
        default

      [{rule, _matcher, _score}] ->
        rule

      tied_matches ->
        filenames =
          tied_matches
          |> Enum.map(fn {rule, _matcher, _score} -> rule.filename end)
          |> Enum.uniq()
          |> Enum.join(", ")

        raise ArgumentError,
              "#{module_name(module)} matches multiple custom Translatable bundles with equal specificity: #{filenames}"
    end
  end

  defp best_custom_matches([]), do: []

  defp best_custom_matches(matches) do
    max_score =
      matches
      |> Enum.map(fn {_rule, _matcher, score} -> score end)
      |> Enum.max()

    Enum.filter(matches, fn {_rule, _matcher, score} -> score == max_score end)
    |> Enum.uniq_by(fn {rule, _matcher, _score} -> rule.filename end)
  end

  defp matcher_score(%Matcher.Submodules{module: parent, score: score}, module) do
    if module == parent or String.starts_with?(module_name(module), module_name(parent) <> ".") do
      score
    end
  end

  defp matcher_score(%Matcher.Exact{module: exact, score: score}, module) do
    if module == exact, do: score
  end

  defp validate_custom_rules!(rules) do
    defaults = Enum.filter(rules, & &1.default?)

    cond do
      length(defaults) != 1 ->
        raise ArgumentError, "bundle_custom requires exactly one default bundle"

      duplicate_filenames = duplicate_custom_filenames(rules) ->
        raise ArgumentError,
              "bundle_custom filenames must be unique: #{Enum.join(duplicate_filenames, ", ")}"

      explicit_without_includes = Enum.find(rules, &(not &1.default? and &1.includes == [])) ->
        raise ArgumentError,
              "custom bundle #{inspect(explicit_without_includes.filename)} requires at least one include matcher"

      true ->
        :ok
    end
  end

  defp duplicate_custom_filenames(rules) do
    duplicates =
      rules
      |> Enum.map(& &1.filename)
      |> Enum.frequencies()
      |> Enum.filter(fn {_filename, count} -> count > 1 end)
      |> Enum.map(fn {filename, _count} -> filename end)

    if duplicates == [], do: false, else: duplicates
  end

  defp shard_id(%__MODULE__{path: "", filename: filename}), do: filename
  defp shard_id(%__MODULE__{path: path, filename: filename}), do: Path.join(path, filename)

  defp bundle_metadata(%__MODULE__{strategy: strategy, path: path, filename: filename}) do
    %{
      "strategy" => Atom.to_string(strategy),
      "path" => path,
      "filename" => filename
    }
  end

  defp custom_bundle_metadata(%__MODULE__{strategy: strategy, path: path}, rule) do
    %{
      "strategy" => Atom.to_string(strategy),
      "path" => path,
      "filename" => rule.filename
    }
  end

  defp custom_shard_id("", filename), do: Path.rootname(filename)
  defp custom_shard_id(path, filename), do: Path.join(path, Path.rootname(filename))

  defp normalize_json_filename(filename) when is_binary(filename) do
    if String.ends_with?(filename, ".json"), do: filename, else: "#{filename}.json"
  end

  defp module_score(module), do: module |> Module.split() |> length()

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp build_path(opts) do
    case Keyword.fetch(opts, :build_path) do
      {:ok, build_path} ->
        build_path

      :error ->
        if Code.ensure_loaded?(Mix.Project) do
          Mix.Project.build_path()
        else
          raise "Translatable extract_path/2 requires :build_path when Mix is unavailable"
        end
    end
  end
end
