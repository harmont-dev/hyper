# `:external` tests shell out to real tools (skopeo/umoci/mke2fs) and touch the
# image DB + media store. They are opt-in: run with `mix test --include external`.
ExUnit.start(exclude: [:external])
