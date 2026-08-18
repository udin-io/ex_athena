import Config

# Machine-local overrides (provider endpoints, model names, log level) belong
# in config/dev.local.exs, which is gitignored. Putting them here or in
# config/config.exs leaks them into every environment — including :test, where
# they break the suite — and into every PR.
if File.exists?(Path.expand("dev.local.exs", __DIR__)) do
  import_config "dev.local.exs"
end
