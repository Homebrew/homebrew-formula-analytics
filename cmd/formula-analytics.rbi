# typed: strict

class Homebrew::Cmd::FormulaAnalyticsCmd
  sig { returns(Homebrew::Cmd::FormulaAnalyticsCmd::Args) }
  def args; end
end

class Homebrew::Cmd::FormulaAnalyticsCmd::Args < Homebrew::CLI::Args
  sig { returns(T::Boolean) }
  def all_core_formulae_json?; end

  sig { returns(T::Boolean) }
  def brew_command_run?; end

  sig { returns(T::Boolean) }
  def brew_command_run_options?; end

  sig { returns(T::Boolean) }
  def brew_test_bot_test?; end

  sig { returns(T::Boolean) }
  def build_error?; end

  sig { returns(T::Boolean) }
  def cask_install?; end

  sig { returns(T.nilable(String)) }
  def days_ago; end

  sig { returns(T::Boolean) }
  def homebrew_devcmdrun_developer?; end

  sig { returns(T::Boolean) }
  def homebrew_os_arch_ci?; end

  sig { returns(T::Boolean) }
  def homebrew_prefixes?; end

  sig { returns(T::Boolean) }
  def homebrew_versions?; end

  sig { returns(T::Boolean) }
  def install?; end

  sig { returns(T::Boolean) }
  def install_on_request?; end

  sig { returns(T::Boolean) }
  def json?; end

  sig { returns(T::Boolean) }
  def os_version?; end

  sig { returns(T::Boolean) }
  def setup?; end
end
