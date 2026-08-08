# Releasing

This repository uses RubyGems.org Trusted Publishing. The release workflow
does not store a long-lived RubyGems API key.

## One-time RubyGems setup

1. Sign in to RubyGems.org and open
   https://rubygems.org/profile/oidc/pending_trusted_publishers.
2. Create a pending publisher with:
   - Gem name: openai-compatible-errors
   - GitHub repository owner: airouter-dev
   - GitHub repository name: openai-compatible-errors-ruby
   - Workflow filename: release.yml
   - Environment: release
3. In the GitHub repository, ensure the release environment exists. The
   workflow requests id-token: write only for the publishing job.

RubyGems converts the pending publisher into a normal publisher after the first
successful push and adds the account that created it as a gem owner.

## Versioned release

Update VERSION and CHANGELOG.md, run the complete test suite, commit the
change, and create a matching tag:

    bundle exec rake test
    git tag -a v0.1.0 -m "Release v0.1.0"
    git push origin main --follow-tags

The tag starts .github/workflows/release.yml. The action configures a
short-lived OIDC credential, runs the Bundler release task and waits for the
gem to become available. Never paste a RubyGems token into source, CI logs or
chat.
