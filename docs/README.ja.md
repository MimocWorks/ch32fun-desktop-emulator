# CH32fun Desktop Emulator

[English README](../README.md)

CH32fun ベースのファームウェア ELF をデスクトップ上で実行するためのエミュレータです。ファームウェアイメージを読み込み、CPU と周辺バスをエミュレーションし、SSD1306 風 OLED の表示内容を SDL3 + Vulkan でウィンドウ表示します。

## デモ

![CH32fun Desktop Emulator のデモ](emu_demo.gif)

## 機能

- 実行時にファームウェア `.elf` を読み込み
- CPU、flash、RAM、I2C 通信、ボタン入力、OLED VRAM をエミュレーション
- OLED フレームバッファをリサイズ可能なデスクトップウィンドウに表示
- デバッグ向けの headless 実行をサポート
- 環境確認用の最小 SDL プローブ実行ターゲットを同梱

## 必要環境

- Zig
- SDL3 の開発用ライブラリ
- Vulkan ローダー / 開発用ライブラリ
- シェーダーコンパイル用の `glslc`
- `zig build run` 実行時は既定で X11 環境を使用

## ビルド

```sh
zig build
```

生成物:

- `zig-out/bin/ch32fun-desktop-emulator`
- `zig-out/bin/sdl-probe`

## 使い方

ファームウェア ELF を指定して起動します。

```sh
zig build run -- --elf /path/to/firmware.elf
```

主なオプション:

- `--stats`: 1 秒ごとに統計情報を表示
- `--cpu-slice N`: 1 スライスあたりの CPU 実行ステップ数
- `--target-fps N`: UI 表示更新の目標 FPS
- `--headless`: SDL/Vulkan UI を作らずに実行
- `--steps N`: headless 実行時の命令実行数
- `--dump-oled`: headless 実行後に OLED 内容を ASCII で出力

例:

```sh
zig build run -- --elf /path/to/firmware.elf --stats
```

headless 実行例:

```sh
zig build run -- --elf /path/to/firmware.elf --headless --steps 200000 --dump-oled
```

## 操作

- `Space`: エミュレートされたボタンを押す
- `Esc`: 終了
- ウィンドウのクローズボタン: 終了

## SDL 環境確認

メインウィンドウが表示されない場合は、まず SDL 単体の確認を行えます。

```sh
zig build probe
```

## 補助スクリプト

[`tools/run-mopeck.sh`](../tools/run-mopeck.sh) は、関連する Mopeck ファームウェアプロジェクトをビルドしてから、このエミュレータを起動します。

```sh
tools/run-mopeck.sh
```

必要に応じて以下の環境変数を使えます。

- `MOPECK_DIR`
- `EMULATOR_DIR`
- `SDL_VIDEODRIVER`

## ディレクトリ構成

- `src/`: エミュレータ本体
- `shaders/`: OLED 描画用 Vulkan シェーダー
- `tools/`: 補助スクリプト

## ライセンス

GitHub で公開する前に、再利用を許可するならライセンスファイルを追加してください。
