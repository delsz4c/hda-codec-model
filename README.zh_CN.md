[English](README.md) | **简体中文**

# 通用 HD Audio Codec — 可综合 SystemVerilog 模型

Realtek **ALC269 / ALC662 / ALC892 / ALC256** High Definition Audio (HDA) Codec 的
参数化、**可综合**功能级模型,依据公开的《Intel High Definition Audio
Specification, Rev. 1.0a》实现。通过单一 `CHIP_ID` 综合期参数选择目标芯片。

模型使用符合规范的 HDA 控制器总线功能模型(BFM)验证,并可在 AMD/Xilinx Vivado 上干净综合。

## 特性

| 模块 | 说明 |
|------|------|
| HDA 链路 | 40-bit 命令 / 36-bit 响应串行链路(`hda_link`);双泵 **DDR** SDO 采样 + 单泵 **SDR** SDI;对帧内 stream tag 免疫的 DDR 帧同步;零延迟 SDI 响应(Start-of-Frame 当拍驱动 bit 499);三帧初始化(Connect / Turnaround / Address) |
| Verb 引擎 | Get/Set 命令:参数(F00)、连接选择、放大器增益/静音、转换器格式/流、电源状态、Pin 控制、GPIO、Unsolicited 响应等 |
| Widget 寄存器 | 各芯片能力 ROM + 可写 widget 状态 |
| 数据通路 | DAC/ADC 数字样本通路、音量衰减、mixer/mux 路由 |
| **高采样率** | 48 kHz = 1、96 kHz = 2、192 kHz = 4 个 sample block/帧(依据 §3.3.34 Block Multiple)—— 数据通路真实搬运多个样本/帧 |
| **流格式** | `conv_format` 真实生效:位宽(16/20/24-bit)与声道数(单/立体声)改变样本数据 |
| Stream tag | 各 DAC 时隙的 outbound stream-tag 过滤 + SDI 上的 inbound stream tag |
| S/PDIF | 1~2 路独立 S/PDIF 串行输出桩 |
| GPIO | 2~4 个 GPIO,含数据/方向/唤醒/Unsolicited 控制(ALC256 GPIO0 可复用为 DMIC 时钟) |
| 蜂鸣发生器 | 可编程频率方波输出 |
| 电源管理 | D0/D1/D2/D3 状态聚合,各模块 power-ready 状态 |

## 支持芯片

| `CHIP_ID` | 型号 | DAC | ADC | S/PDIF | GPIO | 定位 |
|-----------|------|-----|-----|--------|------|------|
| 0 | ALC269 | 2 | 2 | 2 | 2 | 笔记本/移动端 |
| 1 | ALC662 | 3 | 2 | 1 | 2 | 桌面 5.1 |
| 2 | ALC892 | 4 | 3 | 1 | 4 | 桌面 7.1 |
| 3 | ALC256 | 2 | 2 | 1 | 3 | 超极本/平板 |

PCM 能力(所有芯片):16 / 20 / 24-bit,采样率 44.1 / 48 / 96 / 192 kHz。

## 目录结构

```
rtl/generic/   参数化可综合 RTL(10 个模块)
tb/            测试平台 + HDA 控制器 BFM(codec + 地址协议)
sim/           Vivado 批处理脚本、Icarus Verilog Makefile、时序 XDC
USAGE.md       集成/使用指南
```

## 快速开始

### Vivado 仿真

```powershell
cd sim
vivado -mode batch -source sim_hda_codec.tcl -tclargs all   # 全部四款芯片
vivado -mode batch -source sim_hda_codec.tcl -tclargs 3     # 仅 ALC256
vivado -mode batch -source sim_hda_addr.tcl  -tclargs all   # 地址配置测试
```

### Vivado 综合

```powershell
cd sim
vivado -mode batch -source synth_hda_codec.tcl -tclargs 0   # ALC269
```

### Icarus Verilog

```bash
cd sim
make                 # ALC269(默认)
make CHIP=ALC892     # 任意芯片
make all             # 全部四款芯片
```

> 注意:`hda_link` 使用 SystemVerilog DDR(双时钟沿)。Vivado xsim 为参考流程;
> Icarus Verilog 的支持取决于你的 iverilog 版本。

## 验证

自检测试平台(`tb/hda_codec_tb.sv`)运行 **G0–G15 共 16 组**:标识与能力 ROM、
转换器控制、输出/输入通路、GPIO、蜂鸣、S/PDIF、电源管理、Unsolicited 响应、
响应帧、stream tag,以及 **G15 高采样率/流格式**(验证 48/96/192 kHz 下每帧
1/2/4 个 sample block、位宽屏蔽、单声道复制)。

四款芯片全部 `ALL TESTS PASSED`(0 错误),且全部综合 **0 错误 / 0 严重警告**。

## 架构要点

- **运行时可变、向后兼容的帧几何**:每个 DAC 转换器的时隙跨度由其采样率倍数在
  运行时计算得出;48 kHz 时几何退化为固定单块布局,与原布局完全一致。
- **净室、分层、可综合**设计 —— 参数化顶层下 10 个模块,而非扁平的仿真 class。

## 局限与未实现

本项目是**功能级/协议行为模型**,并非门级或模拟级精确复刻真实芯片。已知局限:

- **音频 I/O 是数字桩**。`hp_out_*`、`front_out_*`、`mic*`、`line*` 等是数字样本
  总线 —— 没有真实 DAC/ADC、模拟前端、mixer 运算或采样率转换器。下游只看到最新样本。
- **音量是移位近似**。放大器增益用 2 的幂次移位(~6 dB/步),而非 HDA 的 0.25 dB dB 表。
- **高采样率仅 DAC 播放侧**。96/192 kHz 在 DAC 通路每帧搬运 2/4 个 block;ADC 采集
  通路仍每帧 1 个 block(其数据源是静态桩,多 block 采集无意义)。
- **44.1 kHz 系列按整数倍近似**。44.1 / 88.2 / 176.4 kHz 复用与 48 kHz 基相同的整数
  块倍数,不建模真实的分数率样本分布(~0.919 样本/帧)。
- **声道 > 2 靠多个转换器**。每个转换器的 sample block 固定为 2 声道容器;环绕声用
  多个立体声转换器(HDA 常规路由),而非单个宽转换器。
- **Verb 覆盖是功能性的,非穷尽**。常用 Get/Set 命令可用;部分罕用 verb、处理系数、
  可选 widget 行为为简化或桩实现。仅建模 Audio Function Group(无 Modem)。
- **Stream 路由是时隙固定 + tag 门控**,而非完全动态的转换器-任意包匹配。
- **电源管理仅状态聚合**(D0–D3 状态),无真实功耗/时钟门控行为或时序。
- **Icarus Verilog 尽力而为**。参考流程是 Vivado xsim;DDR/SystemVerilog 结构不保证
  在所有 iverilog 版本上可编译。

欢迎提交 PR 改进以上任意一项 —— 代码注释里都标注了对应的 HDA 规范章节。

## 关于

本项目在 **Claude Opus 4.8**(Anthropic)辅助下生成,开源出来是为了帮大家省点 token
—— 如果你需要一个可以拿来二次开发或学习的 HD Audio codec 模型,请自取。

这是对**公开**的 Intel HD Audio 规范(Rev. 1.0a)的净室独立实现;不含任何厂商数据手册
或第三方代码。

## 许可证

MIT © 2026 delsz4c —— 见 [LICENSE](LICENSE)。

## 声明

与 Intel、Realtek 无隶属或背书关系。产品名称(Intel、Realtek、"High Definition
Audio"、ALC*)为各自权利人的商标,此处仅用于描述接口兼容性。
