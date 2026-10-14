# Tern plugins

Plugins for [Tern](https://stencil.so/tern).

| Plugin | What it does |
| --- | --- |
| [Kai](kai) | A workspaces sidebar: every session as a card with its agents, files, git changes and branches, plus live agent state |

![Kai in a Tern window](kai/docs/images/hero.png)

<table>
  <tr>
    <td align="center"><img src="kai/docs/images/sidebar.png" width="260" alt="Agents"><br><b>Agents</b><br>Live state per pane: working, running, failed</td>
    <td align="center"><img src="kai/docs/images/changes.png" width="260" alt="Changes"><br><b>Changes</b><br>Unstaged and staged files, stage from the menu</td>
    <td align="center"><img src="kai/docs/images/files.png" width="260" alt="Files"><br><b>Files</b><br>The workspace folder as a tree</td>
  </tr>
  <tr>
    <td align="center"><img src="kai/docs/images/monorepo.png" width="260" alt="Monorepo"><br><b>Monorepos</b><br>Nested repos and submodules, grouped</td>
    <td align="center"><img src="kai/docs/images/refs.png" width="260" alt="Refs"><br><b>Refs</b><br>Branches per repo, ahead and behind</td>
    <td align="center"><img src="kai/docs/images/hosts.png" width="260" alt="Hosts"><br><b>Hosts</b><br>One foldable section per machine</td>
  </tr>
</table>

## Install

```sh
tern plugin install github.com/Yupmoh/tern-plugins/kai
```

Add `--force` to update an installed copy.

## License

[MIT](LICENSE)
