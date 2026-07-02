# HDA Codec 使用说明 — r1p6

通用可综合 High Definition Audio Codec 模型（Intel HDA Spec Rev. 1.0a）。
一套参数化 RTL 通过 `CHIP_ID` 配置为 **ALC269 / ALC662 / ALC892 / ALC256**。

## 目录结构

```
rtl/generic/   参数化 SystemVerilog RTL（顶层 hda_codec_top，链路层 hda_link）
tb/            测试平台 + 标准 HDA 控制器 BFM
sim/           Vivado 仿真 / 综合脚本 + XDC 约束
```

## 芯片配置

| CHIP_ID | 型号   | DAC | ADC | SPDIF | GPIO | 声道 |
|---------|--------|-----|-----|-------|------|------|
| 0       | ALC269 | 2   | 2   | 2     | 2    | 2+2  |
| 1       | ALC662 | 3   | 2   | 1     | 2    | 6    |
| 2       | ALC892 | 4   | 3   | 1     | 4    | 8    |
| 3       | ALC256 | 2   | 2   | 1     | 3    | 4    |

## RTL 例化

```systemverilog
hda_codec_top #(.CHIP_ID(0)) u_codec (   // 0 = ALC269
    .bclk    (hda_bclk),      // 24 MHz 位时钟（控制器提供）
    .reset_n (sys_rst_n),
    .pd_n    (power_down_n),
    // HDA 串行链路
    .sync    (hda_sync),
    .sdo     (hda_sdo),       // 控制器 -> codec，双泵 DDR
    .sdi     (hda_sdi),       // codec -> 控制器，单泵 SDR
    .sdi_oe  (hda_sdi_oe),    // SDI 输出使能（开漏）
    .sdi_in  (hda_sdi_bus),   // SDI 总线回读（地址帧用）
    // 音频输出 / 输入数字桩、GPIO、SPDIF、状态信号……见 hda_codec_top.sv
);
```

链路层为 `hda_link`：双泵 DDR SDO 采样 / 单泵 SDR SDI / DDR-SYNC 帧同步
（对帧内 stream tag 免疫）/ SDI Response 零延迟（Start-of-Frame 驱动 bit 499）。

## 仿真（Vivado xsim）

```powershell
cd sim
vivado -mode batch -source sim_hda_codec.tcl -tclargs all   # 四款芯片，G0–G14
vivado -mode batch -source sim_hda_codec.tcl -tclargs 0     # 仅 ALC269
vivado -mode batch -source sim_hda_addr.tcl  -tclargs all   # 地址枚举测试 A0–A5
```

## 综合（Vivado）

```powershell
cd sim
vivado -mode batch -source synth_hda_codec.tcl -tclargs 0   # 综合 ALC269
```

时序 / 引脚约束见 `sim/hda_codec.xdc`。综合结果：0 errors / 0 critical warnings。

## 测试覆盖

- **hda_codec_tb**（G0–G14）：识别与能力 ROM、Verb 处理、音频输出/输入通路、电源管理、
  SPDIF、BEEP、GPIO、鲁棒性、Response Field 格式（Fig 59）、链路 stream tag（§5.3.2.1）。
- **hda_addr_tb**（A0–A5）：地址枚举协议（赋址、过滤、时序边界、持久性、复位、快速重赋址）。
- 四款芯片全部通过（Errors=0）。

## 关键端口（`hda_codec_top`）

| 类别 | 端口 |
|------|------|
| HDA 链路 | `bclk` `reset_n` `pd_n` `sync` `sdo` `sdi` `sdi_oe` `sdi_in` |
| 音频输出 | `hp_out_*` `front_out_*` `surr_out_*` `clfe_out_*` `side_out_*` `mono_out` |
| 音频输入 | `mic1_*` `mic2_*` `line1_*` `line2_*` |
| 其他 | `gpio[]` `spdif_out[]` `beep_out` `codec_ready` `afg_powered` `dac_powered` `adc_powered` `spdif_powered` |

## 扩展新芯片

1. `hda_codec_pkg.sv` 加 `CHIP_ALCxxxx` 常量并在各 `cfg_*()` 函数加 `case` 分支
2. `hda_widget_regs.sv` 加该芯片的 Widget Cap / Connection List / Pin Cap ROM
3. `hda_audio_path.sv` 的 generate 块加 DAC→Pin 路由和 ADC Mux
（`hda_pwr_mgmt.sv` 自动适配 DAC/ADC/SPDIF 数量，无需改动）
