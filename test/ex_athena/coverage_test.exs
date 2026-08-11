defmodule ExAthena.CoverageTest do
  use ExUnit.Case, async: true

  alias ExAthena.Coverage

  @moduledoc """
  A test run going green proves a test EXISTS, not that it exercises the
  change. A live run wrote `for_week_test.exs` covering a private helper it
  had just written, reported 252 passing, and shipped a page that raised on
  every load — the changed LiveView was never executed by anything.

  Coverage answers the question the other rails cannot: did any test actually
  run this code?
  """

  # Real `mix test --cover` output. Note `Ice.Pervasive.Resource.Appointment`
  # at 100% despite being one of the buggy files: Ash resources are mostly
  # compile-time DSL, so merely loading the module "covers" it. That is why
  # the signal is zero-vs-nonzero, never a threshold.
  @report """
  Percentage | Module
  -----------|--------------------------
       0.00% | IceWeb.AppointmentCalendarLive
      20.83% | Ice.Pervasive.Resource.Appointment.ForWeek
     100.00% | Ice.Pervasive.Resource.Appointment
  -----------|--------------------------
       3.82% | Total
  """

  describe "parse/1" do
    test "reads module percentages out of a coverage table" do
      assert Coverage.parse(@report) == %{
               "IceWeb.AppointmentCalendarLive" => 0.0,
               "Ice.Pervasive.Resource.Appointment.ForWeek" => 20.83,
               "Ice.Pervasive.Resource.Appointment" => 100.0
             }
    end

    test "ignores the Total row, which is not a module" do
      refute Map.has_key?(Coverage.parse(@report), "Total")
    end

    test "finds a table embedded in a worker's prose report" do
      text = "I ran the suite.\n\n#{@report}\nAll good."
      assert Coverage.parse(text)["IceWeb.AppointmentCalendarLive"] == 0.0
    end

    test "returns an empty map when there is no coverage data" do
      assert Coverage.parse("252 tests, 0 failures") == %{}
      assert Coverage.parse(nil) == %{}
    end
  end

  describe "modules_in/1" do
    @tag :tmp_dir
    test "reads the modules a source file defines", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")

      File.write!(path, """
      defmodule Ice.Pervasive.Resource.Appointment do
        defmodule Nested do
        end
      end
      """)

      assert Coverage.modules_in(path) == [
               "Ice.Pervasive.Resource.Appointment",
               "Nested"
             ]
    end

    @tag :tmp_dir
    test "returns nothing for a file that defines no module", %{tmp_dir: dir} do
      path = Path.join(dir, "app.css")
      File.write!(path, ".btn { color: red }")

      assert Coverage.modules_in(path) == []
    end

    test "returns nothing for a file that does not exist" do
      assert Coverage.modules_in("/nonexistent/x.ex") == []
    end
  end

  describe "unexercised/3" do
    @tag :tmp_dir
    test "flags a changed file whose module no test ever ran", %{tmp_dir: dir} do
      live = Path.join(dir, "appointment_calendar_live.ex")
      File.write!(live, "defmodule IceWeb.AppointmentCalendarLive do\nend\n")

      assert {:ok, [^live]} = Coverage.unexercised([live], @report, dir)
    end

    @tag :tmp_dir
    test "accepts a file that was executed, however little", %{tmp_dir: dir} do
      path = Path.join(dir, "for_week.ex")
      File.write!(path, "defmodule Ice.Pervasive.Resource.Appointment.ForWeek do\nend\n")

      assert {:ok, []} = Coverage.unexercised([path], @report, dir)
    end

    # Inflated DSL coverage is why the gate never uses a threshold: this file
    # IS buggy and IS reported at 100%. The gate deliberately lets it pass
    # rather than pretend a percentage means correctness.
    @tag :tmp_dir
    test "accepts a compile-time-heavy module reporting full coverage", %{tmp_dir: dir} do
      path = Path.join(dir, "appointment.ex")
      File.write!(path, "defmodule Ice.Pervasive.Resource.Appointment do\nend\n")

      assert {:ok, []} = Coverage.unexercised([path], @report, dir)
    end

    @tag :tmp_dir
    test "says so when no coverage was reported at all", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")
      File.write!(path, "defmodule A do\nend\n")

      assert :no_data = Coverage.unexercised([path], "252 tests, 0 failures", dir)
    end

    @tag :tmp_dir
    test "ignores files that define no module and files outside the report", %{tmp_dir: dir} do
      css = Path.join(dir, "app.css")
      File.write!(css, ".x{}")

      unknown = Path.join(dir, "b.ex")
      File.write!(unknown, "defmodule NotInReport do\nend\n")

      # A module absent from the report was never loaded, let alone run.
      assert {:ok, [^unknown]} = Coverage.unexercised([css, unknown], @report, dir)
    end

    @tag :tmp_dir
    test "resolves paths relative to the project root", %{tmp_dir: dir} do
      nested = Path.join([dir, "lib", "ice_web", "live"])
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "x.ex"), "defmodule IceWeb.AppointmentCalendarLive do\nend\n")

      assert {:ok, ["lib/ice_web/live/x.ex"]} =
               Coverage.unexercised(["lib/ice_web/live/x.ex"], @report, dir)
    end
  end
end
