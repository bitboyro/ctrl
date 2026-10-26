# Release ctrl

1. Update VERSION and CHANGELOG.md. Use a final X.Y.Z version for publication.
2. Run the checks in docs/contributing.md. Review the built executable and package.
3. Commit, push, then push a matching vX.Y.Z tag when publication is authorized.
4. CI tests Linux/macOS, checks tag/version agreement, builds the executable and
   full archive, and publishes both with SHA256 files.
5. Download the published executable, verify SHA256, and check --version/help.

The executable contains its operation library, contracts, offline help, and skill.
The full tarball adds readable docs, source operations, completions, and examples.
No external skill fetch or automatic production configuration migration occurs.
