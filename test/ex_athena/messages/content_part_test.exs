defmodule ExAthena.Messages.ContentPartTest do
  use ExUnit.Case, async: true
  alias ExAthena.Messages.ContentPart

  describe "text/1" do
    test "returns a :text content part" do
      assert %ContentPart{type: :text, text: "hello"} = ContentPart.text("hello")
    end
  end

  describe "image/2" do
    test "returns an :image content part with explicit media_type" do
      data = <<0, 1, 2>>

      assert %ContentPart{type: :image, data: ^data, media_type: "image/jpeg"} =
               ContentPart.image(data, "image/jpeg")
    end

    test "defaults media_type to image/png" do
      assert %ContentPart{type: :image, media_type: "image/png"} = ContentPart.image(<<0>>)
    end
  end

  describe "image_url/1" do
    test "returns an :image_url content part" do
      assert %ContentPart{type: :image_url, url: "https://example.com/img.png"} =
               ContentPart.image_url("https://example.com/img.png")
    end
  end

  describe "file/3" do
    test "returns a :file content part with explicit media_type" do
      data = "pdf bytes"

      assert %ContentPart{
               type: :file,
               data: ^data,
               filename: "doc.pdf",
               media_type: "application/pdf"
             } = ContentPart.file(data, "doc.pdf", "application/pdf")
    end

    test "defaults media_type to application/octet-stream" do
      assert %ContentPart{type: :file, media_type: "application/octet-stream"} =
               ContentPart.file("bytes", "file.bin")
    end
  end
end
