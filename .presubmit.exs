# Commit policy; run with `mix presubmit`, installed as hooks by `mix presubmit.install`.
[
  # Pre-1.0: public functions are removed outright, without a deprecation cycle.
  {Presubmit.Rules.Elixir, warn: [:removals_deprecated]},
  Presubmit.Rules.Hygiene,
  Presubmit.Rules.Mix,
  # Changelog entries are written in batches at release time, not per commit.
  {Presubmit.Rules.Changelog, warn: [:api_changes_logged]},
  {Presubmit.Rules.ExUnit, only: [:behaviour_changes_tested]},
  {Presubmit.Rules.Message,
   subject: ~r/^\[[a-z_-]+\] [a-z0-9]/,
   max_subject_length: 72,
   trailers: [
     {fn commit ->
        Enum.any?(
          Presubmit.Query.trailer(commit, "Co-Authored-By"),
          &(&1 =~ ~r/anthropic\.com/)
        )
      end, "Claude-Session", ~r{^https://claude\.ai/code/session_}}
   ]},
  {Presubmit.Rules.Shape, max_files: 60, max_additions: 3000}
]
