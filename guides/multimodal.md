# Multimodal (Vision)

ExAthena supports multimodal messages — text plus images — through the
`ExAthena.Messages.ContentPart` struct. Two entry points are available: the
ergonomic `images:` shorthand for quick one-liners, and full `ContentPart`
construction for complex payloads.

## Quick start: `images:` shorthand

Pass `images: [...]` to `ExAthena.query/2`, `ExAthena.stream/3`, or
`ExAthena.run/2` alongside a prompt string:

```elixir
png = File.read!("diagram.png")

{:ok, response} =
  ExAthena.query("Describe what you see",
    provider: :ollama,
    model: "llava",
    images: [%{data: png, media_type: "image/png"}]
  )

IO.puts(response.text)
```

Each entry in the `images:` list may be one of:

| Shape | Description |
|---|---|
| `%{data: binary(), media_type: String.t()}` | Inline image bytes |
| `%{data: binary()}` | Inline image, media type defaults to `"image/png"` |
| `%{url: String.t()}` | Remote image URL |

ExAthena builds a multimodal user message with the text part first, followed
by the image parts. When no prompt is given, the images are merged into the
last user message in `:messages`, or appended as a new user message.

## Full `ContentPart` approach

For finer control — mixing text, images, and files in arbitrary order — build
`ContentPart` structs directly and pass them as the message content:

```elixir
alias ExAthena.Messages
alias ExAthena.Messages.ContentPart

png = File.read!("chart.png")
pdf = File.read!("report.pdf")

parts = [
  ContentPart.text("Summarize the chart and cross-reference the report:"),
  ContentPart.image(png, "image/png"),
  ContentPart.file(pdf, "report.pdf", "application/pdf")
]

{:ok, response} =
  ExAthena.query(nil,
    provider: :claude,
    model: "claude-opus-4-7",
    messages: [Messages.user(parts)]
  )
```

### ContentPart factory functions

| Function | Type | Fields |
|---|---|---|
| `ContentPart.text(content)` | `:text` | `text` |
| `ContentPart.image(data, media_type \\ "image/png")` | `:image` | `data`, `media_type` |
| `ContentPart.image_url(url)` | `:image_url` | `url` |
| `ContentPart.file(data, filename, media_type \\ "application/octet-stream")` | `:file` | `data`, `filename`, `media_type` |

## Provider examples

### Ollama (llava, qwen2-vl)

```elixir
# config/config.exs
config :ex_athena, :ollama,
  base_url: "http://localhost:11434",
  model: "llava"

# usage
png = File.read!("screenshot.png")

{:ok, response} =
  ExAthena.query("What is shown in this screenshot?",
    provider: :ollama,
    model: "llava",
    images: [%{data: png, media_type: "image/png"}]
  )
```

Pull a vision-capable model first:

```bash
ollama pull llava
# or
ollama pull qwen2-vl
```

Ollama vision support is model-dependent. Non-vision models will return an
error or silently ignore image parts.

### OpenAI-compatible (gpt-4o)

```elixir
{:ok, response} =
  ExAthena.query("What's in this image?",
    provider: :openai_compatible,
    model: "gpt-4o",
    images: [%{url: "https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/280px-PNG_transparency_demonstration_1.png"}]
  )
```

For inline images with the OpenAI API:

```elixir
png = File.read!("photo.jpg")

{:ok, response} =
  ExAthena.query("Describe the photo",
    provider: :openai_compatible,
    model: "gpt-4o-mini",
    images: [%{data: png, media_type: "image/jpeg"}]
  )
```

### Anthropic Claude

```elixir
png = File.read!("diagram.png")

{:ok, response} =
  ExAthena.query("Explain this architecture diagram",
    provider: :claude,
    model: "claude-opus-4-7",
    images: [%{data: png, media_type: "image/png"}]
  )
```

Claude supports PNG, JPEG, GIF, and WebP. Maximum image size is 5 MB per
image.

### Google Gemini

```elixir
png = File.read!("chart.png")

{:ok, response} =
  ExAthena.query("What trend does this chart show?",
    provider: :gemini,
    model: "gemini-2.5-flash",
    images: [%{data: png, media_type: "image/png"}]
  )
```

## Using `images:` in the agent loop

`ExAthena.run/2` forwards `images:` to `Request.new/2` so the first turn
has the image attached:

```elixir
png = File.read!("codebase_diagram.png")

{:ok, result} =
  ExAthena.run("Implement the architecture shown in this diagram",
    provider: :claude,
    model: "claude-opus-4-7",
    cwd: "/path/to/project",
    images: [%{data: png, media_type: "image/png"}]
  )
```

## Image format notes

- **Inline images** are sent as base64-encoded data to the provider. The
  `req_llm` adapter handles encoding transparently.
- **Image URLs** (`%{url: ...}`) are forwarded as-is. The provider fetches
  the image at inference time. Not all providers support URL references —
  prefer inline for maximum compatibility.
- **media_type** should match the actual image format (`"image/png"`,
  `"image/jpeg"`, `"image/gif"`, `"image/webp"`). Some providers are lenient;
  others require an accurate MIME type.
- **Multiple images** in one message are supported by all major providers
  (Claude, OpenAI, Gemini). Ollama support is model-dependent.

## Vision support by provider

| Provider | Vision support | Notes |
|---|---|---|
| `:ollama` | Model-dependent | `llava`, `qwen2-vl`, `llava-phi3`, `bakllava` |
| `:openai_compatible` | ✅ `gpt-4o`, `gpt-4o-mini` | URL + inline; other OAI-compat endpoints vary |
| `:claude` | ✅ Any `claude-3`+ model | PNG, JPEG, GIF, WebP; max 5 MB per image |
| `:gemini` | ✅ Any `gemini-1.5`+ model | Inline + URL; very generous size limits |
