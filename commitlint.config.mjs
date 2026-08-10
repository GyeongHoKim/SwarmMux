// Conventional Commits, enforced by the commit-msg hook (see lefthook.yml)
// and re-checked for every pull request in CI.
//
//   feat(ws): add overflow policy option
//   fix: release peer binding on stopped event
//   docs(readme): trim the extension point table
//
// A `!` after the type or scope marks a breaking change, as does a
// `BREAKING CHANGE:` footer. release-please reads these to pick the next
// version, so the type is not cosmetic.
export default {
  extends: ["@commitlint/config-conventional"],
  rules: {
    // Keep subjects readable in `git log --oneline` and in release notes.
    "header-max-length": [2, "always", 72],
    "body-max-line-length": [2, "always", 100],
  },
};
