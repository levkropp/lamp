# Publishing LAMP

Target repository: `levkropp/lamp`. Intended Pages address: `https://levkropp.github.io/lamp/`.

The public repository uses `main`. GitHub Pages serves the root of `gh-pages`, which is generated from `site/`. Versioned Windows archives are attached to prereleases. Local builds, runtime/decoder smoke tests and site checks run before publication. Check the Pages build and live URL after each publication.

From a Windows checkout with Git, GitHub CLI, Node.js, and the build tools:

```powershell
gh auth login
gh auth status
.\scripts\publish.ps1
```

The script obtains the authenticated account ID, checks that the login is `levkropp`, and sets repository-local Git name/email. It defaults to `ID+levkropp@users.noreply.github.com`; if GitHub Settings → Emails shows the older noreply address, pass `-NoreplyEmail levkropp@users.noreply.github.com`. It never uses a personal email address or changes global Git identity.

It builds and verifies the players/site, creates a public repository if absent, commits and pushes without force, publishes `site/` to `gh-pages`, configures branch-based Pages, and creates a 0.3.0 prerelease with the verified archive. Existing nonempty, unrelated remote history is preserved and must be integrated before a push. Existing releases are left intact.

The initial GitHub login has repository access but lacks the `workflow` scope. Branch-based Pages works with that login. Optional build and Pages Actions templates are preserved in `docs/workflows/`. To enable custom Actions later, authorize workflow access, move the templates into `.github/workflows/`, switch the Pages source to GitHub Actions and verify both jobs. Moving the templates is optional; the current website deploys when `gh-pages` changes.

Verify the hosted jobs after publishing:

```powershell
gh api repos/levkropp/lamp/pages
gh api repos/levkropp/lamp/pages/builds/latest
gh run list --repo levkropp/lamp
```

Open the reported Pages URL and test its mobile layout and download/source links. The optional build workflow exercises small committed audio fixtures; the full codec suites remain separate because they require FFmpeg and an audio device for some checks.
