defmodule Noter.SettingsTest do
  use Noter.DataCase, async: false

  alias Noter.Settings

  describe "get/2" do
    test "returns nil for missing key" do
      assert Settings.get("nonexistent") == nil
    end

    test "returns default for missing key" do
      assert Settings.get("nonexistent", "fallback") == "fallback"
    end
  end

  describe "set/2" do
    test "creates new setting" do
      assert {:ok, setting} = Settings.set("my_key", "my_value")
      assert setting.key == "my_key"
    end

    test "updates existing setting" do
      {:ok, _} = Settings.set("my_key", "first")
      {:ok, _} = Settings.set("my_key", "second")

      assert Settings.get("my_key") == "second"
    end
  end

  describe "get/1 decodes JSON types" do
    test "returns decoded string" do
      Settings.set("str", "hello")
      assert Settings.get("str") == "hello"
    end

    test "returns decoded number" do
      Settings.set("num", 42)
      assert Settings.get("num") == 42
    end

    test "returns decoded float" do
      Settings.set("flt", 0.7)
      assert Settings.get("flt") == 0.7
    end

    test "returns decoded map" do
      Settings.set("obj", %{"a" => 1})
      assert Settings.get("obj") == %{"a" => 1}
    end
  end

  describe "all/0" do
    test "returns decoded map of all settings" do
      Settings.set("key1", "val1")
      Settings.set("key2", 99)

      result = Settings.all()
      assert result["key1"] == "val1"
      assert result["key2"] == 99
    end
  end

  describe "configured?/1" do
    test "returns false for missing key" do
      refute Settings.configured?("missing")
    end

    test "returns false for empty string" do
      Settings.set("empty", "")
      refute Settings.configured?("empty")
    end

    test "returns true for set value" do
      Settings.set("url", "http://example.com")
      assert Settings.configured?("url")
    end
  end
end
