# 基本说明

## 源码地址

参考llvm github:
https://github.com/llvm/llvm-project.git
https://gitee.com/mirrors/LLVM.git  （github地址的国内镜像，每日同步）

## 版本选择

基于clang11版本文档翻译
https://releases.llvm.org/11.0.0/tools/clang/docs/InternalsManual.html

选择11.0版本的代码，具体版本如下：

```
commit 1fdec59bffc11ae37eb51a1b9869f0696bfd5312 (HEAD, tag: llvmorg-11.1.0-rc3, tag: llvmorg-11.1.0, origin/release/11.x)
Author: Andi-Bogdan Postelnicu <abpostelnicu@me.com>
Date:   Wed Feb 3 17:38:49 2021 +0000

    [lldb] Fix fallout caused by D89156 on 11.0.1 for MacOS

    Fix fallout caused by D89156 on 11.0.1 for MacOS

    Differential Revision: https://reviews.llvm.org/D95683
```

TODO: **未来可能会按照clang版本形式，将本文档也划分成不同版本**

## 平台

本文的开发调试主要基于Linux平台(Ubuntu/Fedora/CentOS）

# 正文

## 介绍

本文档描述了clang前端中，一些重要API以及内部设计，旨在让读者可以既可以掌握一些高层次的信息，也可以了解背后的一些设计思路。
本文的更针对探索clang内部原理的读者，而不是一般的使用者。下面的描述根据不同的库进行组织，但是并不会描述客户端如何使用它们。

## LLVM支持库

LLVM支持库libSupport提供了一些底层库和数据结构，包括命令行处理、不同的container以及用于文件系统访问的系统抽象层。

## Clang的基础库

这一部分库的名字可能要起得更好一点。这些“基础”库包括：追踪、操作源码buffer和包含的位置信息、诊断、符号、目标平台抽象、以及语言子集的偏基础类的util逻辑。  
部分架构只针对C语言生效（比如TargetInfo），其他部分（比如SourceLocation, SourceManager, Diagnostics,
FileManager）可以用于非C的其他语言。可能未来会引入一个新的库、把这些通用的类移走、或者引入新的方案。  
下面会根据依赖关系，按顺序描述基础库的各个类。

### 诊断子系统

Clang诊断子系统是编译器和用户交互的重要部分。诊断主要指代码错误，或者不太可信的情况下，编译器生成的警告和错误。在Clang中，每个诊断信息包括：
唯一id、对应的英文翻译、sourcelocation信息（用来展示^），严重级别（警告或者错误）。除此之外，还包括可选的一系列参数和代码段信息。  
本节中，我们会看到一些Clang产生的诊断的例子，当然诊断信息可以根据DiagnosticConsumer接口的不同实现从而有各种不同的渲染方式。一个可读的例子如下：

```
t.c:38:15: error: invalid operands to binary expression ('int *' and '_Complex float')
P = (P-42) + Gamma*4;
    ~~~~~~ ^ ~~~~~~~
```
上面这个例子中，可以看到英文翻译、严重级别，源码位置（^号和文件/行/列信息），诊断的参数、代码片段。当然你也知道内部还有个id（笑）  
让这些内容产生需要若干步骤，涉及到很多移动的分片。本节中会描述这些步骤、分片，也会说明增加新诊断信息的一些最佳实践。  

#### The Diagnostic*Kinds.td files
根据需要使用的库，在clang/base/Diagnostic*Kinds.td相应文件中增加一个入口点就可以创建诊断。tblgen会根据文件创建唯一id，严重级别，英文翻译，格式化字符串等。  
这个唯一id在命名上也包含一些信息。有的id以err_，warn_，ext_开头，将严重级别列入到id里面。这些严重级别的枚举与产生相应诊断的C++代码关联，所以这个级别简化有一点意义。   
诊断的严重级别包括这些：{NOTE, REMARK, WARNING, EXTENSION, EXTWARN, ERROR}。ERROR这个诊断说明，代码在任何情况下都是不能被接受的；如果产生了一个error诊断，代码的AST可能都没有完全构建好。EXTENSION 和 EXTWARN 用于Clang可以兼容的语言扩展，也就是说，Clang仍然可以构建AST，但是诊断会提示说代码不是可移植的；EXTENSION 和 EXTWARN 的区别在于，默认情况下，前者是被忽略的，而后者会提示警告。WARNING说明，代码在语法规则下是合法的，但是可能有些地方会有二义性。REMARK则说明相应的代码没有产生二义性。NOTE的话，一般是对之前的诊断做补充（没有实际意义）。  
上面这些级别可以映射到诊断子系统的实际输出的levels信息（Diagnostic::Level 枚举, 包括Ignored, Note, Remark, Warning, Error, Fatal）。Clang内部支持一种粗粒度的映射机制，可以让差不多所有的严重级别都可以和level对应上。不能映射的只有NOTES——其级别依赖前面的诊断——以及ERROR，只能映射到Fatal（换句话说，没法把ERROR级别映射到warning level）。  
诊断映射的应用场景很多。比如，-pedantic这个选项会使得EXTENSION映射到Warning, 如果指定了-pedantic-errors选项，EXTENSION就是Error了。这种机制可以实现类似-Wunused_macros, -Wundef 这样的选项。  
映射Fatal一般只能用于过于严重，从而导致错误恢复机制也无法恢复的情况（然后带来成吨的错误）。比如说，#include文件失败。  

#### 格式化字符串

用于诊断的格式化字符串看起来简单，但是能力却很强大。格式化字符串主要的形式是一个英文字符串，包含了一些参数格式标记。比如
```
"binary integer literals are an extension"
"format string contains '\\0' within the string body"
"more '%%' conversions than data arguments"
"invalid operands to binary expression (%0 and %1)"
"overloaded '%0' must be a %select{unary|binary|unary or binary}2 operator"
    " (has %1 parameter%s1)"
```
上面这些示例中，展示了格式化字符串中一些重要的特点。除了%之外的所有ascii字符都可以以原始格式放到诊断字符串里，不过注意这些是C字符串，所以要注意0字符转义问题（如示例2）。如果需要使用%，就要用转义：%%（示例3）。Clang使用“%...[digit]”这种序列指定参数的位置和格式化方式。  
诊断的参数通过带编号的方式引用：%0-%9，具体编号取决于生成诊断的C++代码。超过10个参数的话，可能某些地方得再考虑一下（笑）。和printf不同，参数在字符串的位置，可以和传递的顺序不同；比如可以通过"%1 %0"的方式交换2个参数。%和数字之外的文本用于格式化指示；如果没有这些指示，参数就只会变成一个单独的字符串。  
制定字符串一些最佳实践如下：
- 短一点。不要超过DiagnosticKinds.td的80长度限制，这样不会导致输出时丢失，也可以让你考虑怎么通过诊断信息表达出更重要的点。
- 多利用位置信息。用户可以看到代码的行和具体的位置，所以不用在字符串中告知比如类似第4个参数有问题之类的。
- 不要大写，结尾不要带.（英文句号）
- 如果要引用什么东西，用单引号  
诊断不要用随机的字符串做参数：比如格式化字符串是“you have a problem with %0” 然后传参是“your argument”或者 “your return value” ；这么做不利于翻译诊断文本到其他语言（因为可能文本被翻译了，但是参数仍然是英文的）；C/C++的关键字，以及操作符这类的情况除外，不过也要注意pointer或者reference不是关键字。换句话说，你可以用代码中出现的所有的东西（变量名、类型、标记等）。使用select方法可以以很本地化的方式达到这样的目的，见下文。

