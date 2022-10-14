
# 基本说明

## 源码地址

参考llvm github:  
<https://github.com/llvm/llvm-project.git>  
<https://gitee.com/mirrors/LLVM.git>  （github地址的国内镜像，每日同步）  

## 版本选择

基于clang11版本文档翻译  
<https://releases.llvm.org/11.0.0/tools/clang/docs/DriverInternals.html>

选择11.0版本的代码，具体版本如下：

```
commit 1fdec59bffc11ae37eb51a1b9869f0696bfd5312 (HEAD, tag: llvmorg-11.1.0-rc3, tag: llvmorg-11.1.0, origin/release/11.x)
Author: Andi-Bogdan Postelnicu <abpostelnicu@me.com>
Date:   Wed Feb 3 17:38:49 2021 +0000

    [lldb] Fix fallout caused by D89156 on 11.0.1 for MacOS

    Fix fallout caused by D89156 on 11.0.1 for MacOS

    Differential Revision: https://reviews.llvm.org/D95683
```
## 平台

本文的中的附加内容需要实际开发运行的部分，相关的开发调试主要基于Linux平台(Ubuntu/Fedora/CentOS）  
推荐使用VSCode作为IDE开发：<https://code.visualstudio.com/>

## 备注

本文中的引用是本人自己添加的，不是原文的翻译。
> 这段文字是我添加的内容
> ```
> 这段代码是我添加的内容
> ```

TODO: **未来可能会按照clang版本形式，将本文档也划分成不同版本**  
FIXME: **文中出现的其他链接，部分会链接到llvm docs的原始网站，如果未来对应文档也有翻译的话，会同步修正为本书内部的链接。**

# ---以下为正文---

# 介绍

本文档描述了Clang的驱动器，主要目的是描述驱动器的产生的动机以及设计目标，也包括内部实现的细节解释。

# 特性和目标

Clang驱动器期望是成为可以用于实际生产的高质量的编译器驱动器。Clang驱动通过和gcc驱动器兼容的命令行方式，提供了对Clang编译器和工具的访问能力。  
尽管此驱动器属于Clang项目的一部分，并且由Clang项目推进；在逻辑上，它是一个和Clang有很多共同目标的独立工具。

## GCC兼容性

Clang驱动设计的第一号目标，就是可以让用户可以更容易地去接受将Clang应用到原本被设计使用GCC的构建系统。尽管这会使驱动比起需求会更加复杂；但是让驱动在命令行接口上和gcc一致仍然值得这么做，因为这样可以让用户更快速的在其项目中进行测试。

## 灵活性

驱动设计上很灵活，在clang和LLVM架构增长时，很容易纳入新的用法。比如，驱动器可以很容易为引入已集成汇编器的工具添加支持，这个特性希望未来LLVM也能具备。

出于同样考虑，大部分的驱动的能力都是通过库提供的。这些库可以用来构建其他实现或者提供gcc相似的接口的工具。

## 低开销

驱动本身应该是开销越低越好。实践中发现，gcc的驱动自身在编译很多小文件时，会带来很少但是也不能忽视的开销。
比起编译过程来讲，驱动的工作不多，但是仍然需要通过一些原则使其尽量高效：

- 尽可能避免字符串的分配与复制
- 参数只解析一次
- 为高效查询的参数提供一些简单接口

> 第三点是说：编译命令可能会有N多参数；可以提供一些接口支持高效的查询，比如提供接口，输入参数的名字就可以直接定位内容之类。

## 保持简单

最后，在满足其他目标的前提下，这个驱动的设计应该尽量简单。需要注意到，尝试兼容gcc驱动这个目标会带来巨大的复杂性。不过，驱动的设计会通过将整个流程划分成若干个独立阶段，避免耦合成一整块任务的方式减少复杂程度。

# 内核设计与实现

## 内核介绍

为了实现上面提到的目标，驱动设计上可以完整包含gcc的能力，也就是说，不应该再委托gcc来完成细粒度的任务。
在Darwin中，Clang驱动器会进一步包含gcc驱动器的功能，来支持构建通用镜像（二进制和目标文件）能力。这也需要驱动器可以直接调用语言相关的编译器（比如cc1），也就是说，驱动必须记录足够的信息来将参数正确转发给子进程。

## 设计总览

下图展示了驱动架构中的重要组件和相互关系。橙色部分代表驱动创建的具体的数据结构，绿色部分指明操作这些数据结构的概念上独立的阶段，蓝色部分是一些重要的辅助类。

<p align="center">
<img src="https://releases.llvm.org/11.0.0/tools/clang/docs/_images/DriverArchitecture.png">
</p>

## 驱动阶段

驱动器的功能在在概念上分为5个阶段：

1. 解析：选项解析

命令行参数字符串被分解成若干个argument(`Arg`类的实例)。驱动期望理解所有的可用选项，不过有一些情况是只需要解析特定类型的选项的（比如-Wl）。  

每个参数都唯一对应一个抽象的`Option`定义，这个定义描述参数和附加的元信息是如何解析的。Arg的实例本身是很轻量的，只包含用于确定其对应哪个选项，和（附加参数的）相应值。  

比如，命令行`-lfoo -l foo`会被解析成2个Arg实例（一个JoinedArg和一个SeparateArg），但是都指向同一个`Option`。

Option会被延迟创建，防止在驱动加载时载入全部的Option信息。大部分的驱动代码只需要通过option的独立id（比如`options::OPT_I`）就可以处理之。  

Arg实例本身不会存储附加参数的值。很多情况下，存储这类值会带来不必要的字符串复制行为。Arg实例一般都是内嵌在一个包含了原始参数字符串的ArgList结构内部的。每个Arg实例只需要持有在该ArgList中的索引，而不用直接存储具体的值。  

Clang驱动器可以通过-###选项dump出解析阶段的结果（当然在-###选项后要跟着实际的命令行参数），比如：  

```
$ clang -### -Xarch_i386 -fomit-frame-pointer -Wa,-fast -Ifoo -I foo t.c
Option 0 - Name: "-Xarch_", Values: {"i386", "-fomit-frame-pointer"}
Option 1 - Name: "-Wa,", Values: {"-fast"}
Option 2 - Name: "-I", Values: {"foo"}
Option 3 - Name: "-I", Values: {"foo"}
Option 4 - Name: "<input>", Values: {"t.c"}
```
本阶段完成之后，命令行参数就会被分解到良好定义的选项对象中，其对应的参数也会被纳入。后续的阶段就基本不需要做什么（命令行参数的）字符串处理了。

2. 管道：编译动作构建

参数被解析完成之后，需要按照期望的编译顺序构造相应的由子进程执行的任务树。这包括选择输入文件，判定这些文件的类型，针对这些文件需要进行的编译工作（预处理，编译，汇编，链接等），以及对每个任务构造一个`Action`实例的列表。本阶段的结果是操作/操作集的列表，列表的每个操作/操作集都会对应一个单独的输出（比如目标文件或者是链接后的可执行文件）。

大部分的`Action`对象都对应实际的任务，除了2类特殊Action。第一个是InputAction，其行为是将输入的参数转化为其他Action的输入；另一个是BindArchAction，用于概念上切换所有输入Action使用的架构。

Clang驱动器可以通过`-ccc-print-phases`dump本阶段的结果，比如：  

```
$ clang -ccc-print-phases -x c t.c -x assembler t.s
0: input, "t.c", c
1: preprocessor, {0}, cpp-output
2: compiler, {1}, assembler
3: assembler, {2}, object
4: input, "t.s", assembler
5: assembler, {4}, object
6: linker, {3, 5}, image
```

这里驱动器构造了7个独立的操作，前4个是将"t.c"编译成目标文件，4,5是将"t.s"作为输入进行汇编，最后一个是将其链接。

下面是一个大不同的编译管道。这个例子中有2个顶级操作将输入编译成各自的目标文件，目标文件各自使用了`lipo`按照相应架构去融合构建的结果：
```
$ clang -ccc-print-phases -c -arch i386 -arch x86_64 t0.c t1.c
0: input, "t0.c", c
1: preprocessor, {0}, cpp-output
2: compiler, {1}, assembler
3: assembler, {2}, object
4: bind-arch, "i386", {3}, object
5: bind-arch, "x86_64", {3}, object
6: lipo, {4, 5}, object
7: input, "t1.c", c
8: preprocessor, {7}, cpp-output
9: compiler, {8}, assembler
10: assembler, {9}, object
11: bind-arch, "i386", {10}, object
12: bind-arch, "x86_64", {10}, object
13: lipo, {11, 12}, object
```

本阶段完成之后，编译流程就被划分为多个操作，执行这些操作会获得相应的中间/最终输出（某些场景，比如`-fsyntax-only`是没有实际的最终输出的）。Phases指的是大家很熟悉的编译步骤，比如预处理，编译，汇编，链接等。

3. 绑定：工具和文件名的选择

本阶段（和翻译阶段结合）将Action树转成要运行的实际的一系列子进程。概念上，驱动器会执行上层的匹配，将`Action`赋值给相应的`Tool`对象。`ToolChain`用于选择合适的工具执行特定的操作，选好之后，驱动器会和实际的工具交互判断是否可以执行其他的操作（比如，是否有集成的预处理器）

所有的操作都已经选好对应的`Tool`之后，驱动器还要确定这些`Tool`对象要如何连接（比如，通过进程内的模块、管道、临时文件、命名文件之类）。如果指定了输出文件，驱动器也会计算合适的文件名（根据类型或者类似`-save-temps`这样的选项确定文件的后缀或者位置）。

驱动器也会和`ToolChain`交互来执行`Tool`绑定。`ToolChain`包含针对特定架构、平台、操作系统进行编译的全部工具的信息。驱动器的一次编译中，为了和用于不同架构的工具进行交互，可能会调用多个`ToolChain`实例。

本阶段的执行结果不会直接被计算（？）但是驱动可以通过`-ccc-print-bindings`选项输出这些结果。比如：
```
$ clang -ccc-print-bindings -arch i386 -arch ppc t0.c
# "i386-apple-darwin9" - "clang", inputs: ["t0.c"], output: "/tmp/cc-Sn4RKF.s"
# "i386-apple-darwin9" - "darwin::Assemble", inputs: ["/tmp/cc-Sn4RKF.s"], output: "/tmp/cc-gvSnbS.o"
# "i386-apple-darwin9" - "darwin::Link", inputs: ["/tmp/cc-gvSnbS.o"], output: "/tmp/cc-jgHQxi.out"
# "ppc-apple-darwin9" - "gcc::Compile", inputs: ["t0.c"], output: "/tmp/cc-Q0bTox.s"
# "ppc-apple-darwin9" - "gcc::Assemble", inputs: ["/tmp/cc-Q0bTox.s"], output: "/tmp/cc-WCdicw.o"
# "ppc-apple-darwin9" - "gcc::Link", inputs: ["/tmp/cc-WCdicw.o"], output: "/tmp/cc-HHBEBh.out"
# "i386-apple-darwin9" - "darwin::Lipo", inputs: ["/tmp/cc-jgHQxi.out", "/tmp/cc-HHBEBh.out"], output: "a.out"
```
这里展示了绑定到该编译序列的工具链，工具，输入和输出。这里Clang用于编译t0.c，darwin相关的工具用来汇编和链接，而针对PowerPC平台则是用的gcc的工具。

4. 翻译：工具相关的参数翻译

当某个`Tool`被选中用于执行`Action`时，这个`Tool`必须构建具体的在编译过程中执行的`Command`实例。翻译过程中最主要的工作就是从gcc风格的命令行选项转换成子进程实际需要的选项。  
部分工具，比如汇编器，只能处理少量的参数，也只能确定可执行文件的位置并将输入输出参数传递过去。其他工具，比如编译器、链接器，就需要附带翻译大量的参数。  

ArgList类提供了很多简单的辅助方法用于帮助翻译参数，比如，只把参数中的最后一个传给某个选项，或者把参数全部传给某个选项。  

本阶段的执行结果是一堆要执行的`Command`对象（包括可执行文件路径和对应的参数字符串）。

5. 执行

最后，执行编译管道。这个基本就是直接执行了，不过还需要处理一些选项的交互，比如`-pipe`、`-pass-exit-codes`和`-time`。

# 附注

## Compilation对象

驱动器会针对每一个命令行参数集合构造一个Compilation对象。`Driver`本身设想是在构造`Compilation`的过程中保持不变的。例如说，IDE可以使用一个单独的长期驱动实例贯穿整个编译过程始终。  

Compilation对象记录了针对一个特性编译序列的信息。比如，使用的临时文件（编译结束后必须删除）和结果文件（编译失败时必须删除）列表。

## 统一的解析和管道

设计上，解析和管道执行的时候都不关联Compilation对象。驱动器期望这些phase的处理都是平台独立的，包含一些良好定义的异常，比如某个平台是否使用了驱动器。

## 工具链参数翻译

为了尽量贴近gcc，


