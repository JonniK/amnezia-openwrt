# Screenshots for README

Save the four PNGs below with these exact names. The top-level README
references them by relative path; renaming breaks the links.

| Filename | What to capture |
|---|---|
| `luci-amnezia-overview.png` | Full panel scroll: AmneziaWG tunnel section + PBR row + RU IP list + DPI desync (zapret) sections at minimum. Hide LAN IPs / endpoint hosts if you want them out of public view. |
| `luci-amnezia-probe.png` | The "Domain probe" section with a result rendered. A `direct_geoblocked` verdict (e.g. `chatgpt.com`) is the most informative because it shows the coloured chip + reason + recommendation. |
| `luci-amnezia-verify.png` | "Verify list" with the table populated -- ideally a mix of verdicts (1-2 ok, 1 geoblocked, 1 unreachable) so the summary chips and the action hint at the bottom are visible. |
| `luci-amnezia-blockcheck.png` | "Blockcheck" section mid-run -- live log scrolling, "Running..." button state, elapsed timer. The Apply candidates list visible below it is a bonus. |

## Tips

- Use 1400px-wide window so screenshots are sharp at standard README
  rendering (~900px). The LuCI layout is fluid -- narrower windows make
  the right-side controls wrap awkwardly.
- Hide sensitive bits before snapping: peer endpoint IPs, your LAN
  range if you don't want it public.
- Light mode is the LuCI default; dark mode is a UCI option some users
  enable. Either is fine for v0.2.

After you save the files here, run:

```sh
git add docs/screenshots/*.png
git commit -m "docs(readme): add LuCI panel screenshots"
git push
```

and they'll render in the top-level README.
