# GitHub 账号申诉要点（英文，可直接提交）

提交入口：https://support.github.com/contact （选 "Account access / Suspended account"）

---

**Subject:** Request to review suspension of account `lifeifan381`

Hello GitHub Support,

My account `lifeifan381` was suspended and I would like to request a manual
review. The account and its repositories (e.g. `lifeifan381/dsh-ios`) now return
`403 Account suspended` / `404`.

What the account was doing when it was suspended:

- I was running a single GitHub Actions workflow (`build-node-ios`) on
  `lifeifan381/dsh-ios`, triggered by hand with `workflow_dispatch`.
- The workflow builds Node.js for iOS on a `macos-15` hosted runner. Builds take
  60–100 minutes each and I triggered roughly 10 runs over ~6 hours while
  debugging a cross-compilation toolchain.
- No cryptocurrency, no spam, no mass account creation, no scraping.

I understand that repeated long `macos` jobs from a new account can look like
abuse. This was legitimate open-source-style work on my own device porting
project; the repository is public and contains only build scripts.

I am happy to:
- reduce workflow frequency,
- keep the repository read-only apart from my own pushes,
- delete build artifacts that are no longer needed,
- or migrate the CI workload elsewhere if that is preferred.

Could you please review the suspension and, if possible, restore the account?
If any specific action triggered it, I would appreciate knowing which one so I
can avoid it.

Thank you,
`lifeifan381`

---

## 提交时的几个注意

- 用**注册邮箱**提交，别用一次性邮箱
- 附上最近一次运行的 run id（如果页面还能看到）与仓库名
- 一次提交只讲一件事，别写成长篇
- 回复周期通常 1–3 个工作日
