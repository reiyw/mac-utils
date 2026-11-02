# extdisplay

USB-C 1 本で映像出力と給電を兼ねている外部ディスプレイを、ケーブルを挿したまま無効化し、内蔵ディスプレイだけで作業できるようにする。
ケーブルを抜かないので、給電（充電）は続く。
メニューバーに常駐させれば、⌃⌥⌘D で切り替えられる。

動作確認環境: macOS 27.0.1、MacBook と Dell S2722DC（USB-C 接続、65W 給電）

## 必要なもの

- macOS
- `swiftc`（Xcode Command Line Tools。`xcode-select --install` で入る）

## インストール

```sh
./install.sh              # ビルドして ~/.local/bin に置き、メニューバー常駐をログイン時に自動起動する
./install.sh --no-agent   # CLI だけ使う
./install.sh --uninstall  # 無効化中なら復帰させてから削除する
```

`~/.local/bin` を `PATH` に入れておく。

## 使い方

```sh
extdisplay status    # ディスプレイの一覧、ミラー構成、蓋の開閉
extdisplay off       # 外部ディスプレイを無効化
extdisplay on        # 外部ディスプレイを復帰
extdisplay toggle    # off と on を切り替え
extdisplay menubar   # メニューバーに常駐（install.sh が LaunchAgent として起動する）
```

ショートカットを変えるには、`extdisplay.swift` の `registerHotKey()` にあるキーコードと修飾キーを書き換える。

## 動作

- **off**：ミラーリング中なら先に解除し、内蔵ディスプレイがアクティブになったことを確認してから外部ディスプレイを無効化する。
- **on**：外部ディスプレイを有効化する。`off` の前にミラーリングしていた場合は、その構成に戻す。

無効化した外部ディスプレイはオンライン一覧から消える。
そのため、復帰に使うディスプレイ ID と元のミラー構成を `~/.extdisplay-disabled` に保存する。

構成の変更はすべて `.forSession` で適用するので、ログアウトすると元に戻る。
実行ログは `~/Library/Logs/extdisplay.log` に追記される。

## 安全策

画面が 1 枚も映らない状態を避けるため、次の場合は `off` を中止する。

- 蓋が閉じている（`IOPMrootDomain` の `AppleClamshellState` で判定）
- ミラー解除後に、内蔵ディスプレイがアクティブにならない

`--force` を付けると、これらの確認を省く。

## 戻らなくなったとき

次の順に試す。

1. `extdisplay on`
2. USB-C ケーブルを抜き差しする
3. ログアウトしてログインし直す

## 制約

外部ディスプレイの無効化には、非公開 API の `CGSConfigureDisplayEnabled`（見つからなければ SkyLight の `SLSConfigureDisplayEnabled`）を使う。
macOS のアップデートで動かなくなる可能性がある。

その場合の代替として、モニター側で電源オフ中も USB-C 給電を続ける設定にし、モニターの電源ボタンで消す方法がある。
Dell S2722DC では、OSD の「USB-C Charging」を「On in Off Mode」にする。
