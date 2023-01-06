编译前端库主要提供了基于Clang库构建工具（二次开发）的能力，比如一些输出诊断的方法。  

# 调用编译器

编译前端库提供的类中，其中一个是`CompilerIncovation`，这个类保存了描述当前调用Clang的`-cc1`前端的信息。这些信息一般来自Clang驱动器构建的命令行或者执行特殊初始化逻辑的客户端。这个数据结果被分成多个不同的逻辑单元，由编译器的不同部分使用，比如`PreprocessorOptions`，`LanguageOptions`和`CodeGenOptions`。

# 命令行接口

Clang的`-cc1`前端的命令行接口和驱动选项一起，在`clang/Driver/Options.td`中定义。组成一个选项定义需要前缀信息和名字（比如`-std=`），格式，选项值的位置，帮助文本，别名或者其他。选项一般会划到特定的分组下，包含一个或多个flag的标记。由`-cc`前端处理的选项需要标记`CC1Option`flag。

# 命令行解析

选项定义在编译期构建的早期阶段中，通过`-gen-opt-parser-defs`这个表生成后端处理。处理之后，选项会被用于查询llvm::opt::ArgList实例，llvm::opt::ArgList是命令行参数的wrapper。这个步骤有两个地方用到：Clang驱动执行，目的是根据驱动参数构建独立的job；`CompilerInvocation::CreateFromArgs`函数中执行，目的是解析`-cc1`前端的参数。

# 命令行生成

`-cc1`的命令行创建合法的`CompilerInvocation`对象可以通过约定俗成的方式序列化成等效的命令行。这可以用于隐式发现，显示构建的模块。

# 添加新的命令行选项

添加新的命令行选项时，首先需要注意的地方是声明对应选项类的头文件（比如，`CodeGenOptions.h`用于影响代码生成的命令行选项。这样为选项的值添加新的成员变量：
```
  class CodeGenOptions : public CodeGenOptionsBase {

+   /// List of dynamic shared object files to be loaded as pass plugins.
+   std::vector<std::string> PassPlugins;

  }
```

下一步，在表生成文件`clang/include/clang/Driver/Options.td`中声明选项的命令行接口，具体的方式是实例化一个`Option`类（在`llvm/include/llvm/Option/OptParser.td`中定义）。该类的实例在如下辅助类按照指定方式编码命令行选项时被创建：
- `Flag`：这个选项不需要选项的值
- `Joined`：选项的值和选项的名字在同一参数内，紧随其后
- `Separate`：选项的值是在选项名称之后的下一个命令行参数。
- `JoinedOrSeparate`：选项的值既可以按照`Joined`指定，也可以按照`Separate`
- `CommaJoined`：选项的多个值由","分隔，和选项名在同一参数内，紧随其后。

这些辅助类可以处理支持的前缀列表（比如"-"，"--"，"/"）和选项名字：

```
  // Options.td

+ def fpass_plugin_EQ : Joined<["-"], "fpass-plugin=">;
```

接下来，指定附加的属性信息：

- `HelpText`保存了用户需要该选项的帮助信息（比如通过`clang --help`）时，需要输出的文字。
- `Group`指定了选项所属的选项组，该字段在不同工具筛选特定选项时用到。
- `Flags`包含一些和该选项相关的"标签"信息。可以通过标签完成比`Group`更细粒度的筛选。
- `Alias`指明该选项是其它选项的别名，会合并到`AliasArg`类中。

```
// Options.td

  def fpass_plugin_EQ : Joined<["-"], "fpass-plugin=">,
+   Group<f_Group>, Flags<[CC1Option]>,
+   HelpText<"Load pass plugin from a dynamic shared object file.">;

```

新的选项会由Clang驱动识别（除了被标记`NoDriverOption`flag的）。另外，如果是需要用到`-cc1`前端的选项，必须显式标记`CC1Option`flag。

接下来，在Clang驱动中解析（或者生成）相应的命令行参数，并用这些参数构建job。

```
  void Clang::ConstructJob(const ArgList &Args /*...*/) const {
    ArgStringList CmdArgs;
    // ...

+   for (const Arg *A : Args.filtered(OPT_fpass_plugin_EQ)) {
+     CmdArgs.push_back(Args.MakeArgString(Twine("-fpass-plugin=") + A->getValue()));
+     A->claim();
+   }
  }
```

最后一步是在`CompilerInvocation`类实现`-cc1`参数的解析/生成逻辑，初始化/序列化相应的`Option`类（本示例中为`CodeGenOptions`）。这可以通过在选项定义中加入marshalling注解的方式自动完成。

```
  // Options.td

  def fpass_plugin_EQ : Joined<["-"], "fpass-plugin=">,
    Group<f_Group>, Flags<[CC1Option]>,
    HelpText<"Load pass plugin from a dynamic shared object file.">,
+   MarshallingInfoStringVector<CodeGenOpts<"PassPlugins">>;
```

内部的工作在marshalling架构这一节描述，可用的注解信息列到了这里。

如果marshalling架构不能支持期望的语法，考虑将其简化来适配现有的模式。这样可以让命令行格式更统一，减少专用的、人工处理的代码量。记住`-cc1`的命令行接口是专门为Clang的开发者用的，意味着其不需要作为驱动接口的镜像、做后向兼容、或者和GCC兼容。  

如果选项的语法不能通过marshalling注解来编码，那么可以转为用人工手写解析/序列化的方式实现。  

```
  // CompilerInvocation.cpp

  static bool ParseCodeGenArgs(CodeGenOptions &Opts, ArgList &Args /*...*/) {
    // ...

+   Opts.PassPlugins = Args.getAllArgValues(OPT_fpass_plugin_EQ);
  }

  static void GenerateCodeGenArgs(const CodeGenOptions &Opts,
                                  SmallVectorImpl<const char *> &Args,
                                  CompilerInvocation::StringAllocator SA /*...*/) {
    // ...

+   for (const std::string &PassPlugin : Opts.PassPlugins)
+     GenerateArg(Args, OPT_fpass_plugin_EQ, PassPlugin, SA);
  }
```

最后，可以通过`clang -fpass-plugin=a -fpass-plugin=b`这样的方式指定命令行参数，并按照希望的方式使用Option类的新成员变量的值。

```
  void EmitAssemblyHelper::EmitAssemblyWithNewPassManager(/*...*/) {
    // ...
+   for (auto &PluginFN : CodeGenOpts.PassPlugins)
+     if (auto PassPlugin = PassPlugin::Load(PluginFN))
+        PassPlugin->registerPassBuilderCallbacks(PB);
  }
```

# 选项marshalling架构

选项marshalling架构会自动完成将`-cc1`前端的命令行参数转换输入`CompilerInvocation`或者由`CompilerInvocation`生成参数的过程。这个系统将大量的重复而简单的代码转成可被声明并进行表生成的注解，被应用到绝大部分的`-cc1`命令行接口的解析中。本节对该系统做一个概述。  

**注意：** marshalling架构不适用于专用于驱动的选项。只有为`-cc1`提供的选项才需要从/向`CompilerInvocation`进行参数的marshall操作。  

为了读取和修改`CompilerInvocation`的内容，marshalling系统使用关键路径，这些关键路径通过2个步骤声明。首先，继承`KeyPathAndMacro`类，添加`CompilerInvocation`成员的表生成定义：
```
// Options.td

class LangOpts<string field> : KeyPathAndMacro<"LangOpts->", field, "LANG_"> {}
//                   CompilerInvocation member  ^^^^^^^^^^
//                                    OPTION_WITH_MARSHALLING prefix ^^^^^

```

上述模板中，父类（`KeyPathAndMacro类`）第一个模板参数是引用`CompilerInvocation`成员的关键路径。这个参数，如果该成员是指针类型，结尾就是`->`；如果是值类型，结尾就是`.`。子类需要一个单独的参数`field`，该参数和父类的第二个模板参数一致。那么子类可以这样用：`LangOpts<"IgnoreExceptions">`就是构建一个关键路径指向`LangOpts->IgnoreExceptions`成员。父类的第三个模板参数是一个字符串，该字符串会被表生成后台作为`OPTION_WITH_MARSHALLING`宏的前缀。在`Option`实例中，使用上面的关键路径，就会让表生成后台生成如下代码：

```
// Options.inc

#ifdef LANG_OPTION_WITH_MARSHALLING
LANG_OPTION_WITH_MARSHALLING([...], LangOpts->IgnoreExceptions, [...])
#endif // LANG_OPTION_WITH_MARSHALLING
```

这样的定义可以用于命令行参数的解析和生成的相关函数中。

```
// clang/lib/Frontend/CompilerInvoation.cpp

bool CompilerInvocation::ParseLangArgs(LangOptions *LangOpts, ArgList &Args,
                                       DiagnosticsEngine &Diags) {
  bool Success = true;

#define LANG_OPTION_WITH_MARSHALLING(                                          \
    PREFIX_TYPE, NAME, ID, KIND, GROUP, ALIAS, ALIASARGS, FLAGS, PARAM,        \
    HELPTEXT, METAVAR, VALUES, SPELLING, SHOULD_PARSE, ALWAYS_EMIT, KEYPATH,   \
    DEFAULT_VALUE, IMPLIED_CHECK, IMPLIED_VALUE, NORMALIZER, DENORMALIZER,     \
    MERGER, EXTRACTOR, TABLE_INDEX)                                            \
  PARSE_OPTION_WITH_MARSHALLING(Args, Diags, Success, ID, FLAGS, PARAM,        \
                                SHOULD_PARSE, KEYPATH, DEFAULT_VALUE,          \
                                IMPLIED_CHECK, IMPLIED_VALUE, NORMALIZER,      \
                                MERGER, TABLE_INDEX)
#include "clang/Driver/Options.inc"
#undef LANG_OPTION_WITH_MARSHALLING

  // ...

  return Success;
}

void CompilerInvocation::GenerateLangArgs(LangOptions *LangOpts,
                                          SmallVectorImpl<const char *> &Args,
                                          StringAllocator SA) {
#define LANG_OPTION_WITH_MARSHALLING(                                          \
    PREFIX_TYPE, NAME, ID, KIND, GROUP, ALIAS, ALIASARGS, FLAGS, PARAM,        \
    HELPTEXT, METAVAR, VALUES, SPELLING, SHOULD_PARSE, ALWAYS_EMIT, KEYPATH,   \
    DEFAULT_VALUE, IMPLIED_CHECK, IMPLIED_VALUE, NORMALIZER, DENORMALIZER,     \
    MERGER, EXTRACTOR, TABLE_INDEX)                                            \
  GENERATE_OPTION_WITH_MARSHALLING(                                            \
      Args, SA, KIND, FLAGS, SPELLING, ALWAYS_EMIT, KEYPATH, DEFAULT_VALUE,    \
      IMPLIED_CHECK, IMPLIED_VALUE, DENORMALIZER, EXTRACTOR, TABLE_INDEX)
#include "clang/Driver/Options.inc"
#undef LANG_OPTION_WITH_MARSHALLING

  // ...
}
```

`PARSE_OPTION_WITH_MARSHALLING`和`GENERATE_OPTION_WITH_MARSHALLING`宏定义在`CompilerInvocation.cpp`中，实现了解析/生成命令行参数的一些通用的算法。  

# 选项Marshalling注解

表生成后台怎么知道在生成的`Options.inc`文件中，`[...]`里面的内容呢？这通过接下来描述的`Marshalling`的辅助方法指定。这些所有的辅助方法会接受关键路径，以及其他在解析生成命令行参数时可能需要的信息作为参数。

注意：marshalling结构不能用于驱动专用的选项。只有用于`-cc1`前端的选项可以在`CompilerInvocation`之间做marshalling。

## 存在标记

关键路径默认为`false`，如果命令行指定该标记则为`true`。
```
def fignore_exceptions : Flag<["-"], "fignore-exceptions">, Flags<[CC1Option]>,
  MarshallingInfoFlag<LangOpts<"IgnoreExceptions">>;
```

## 不存在标记

关键路径默认为`true`，如果命令行指定该标记则为`false`。
```
def fno_verbose_asm : Flag<["-"], "fno-verbose-asm">, Flags<[CC1Option]>,
  MarshallingInfoNegativeFlag<CodeGenOpts<"AsmVerbose">>;
```

## 不存在/存在标记

关键路径默认为指定的值（可能为true, false；也有可能是不能从文件中直接确定的），然后关键路径的值设置为命令行中出现的flag对应的值。
```
defm legacy_pass_manager : BoolOption<"f", "legacy-pass-manager",
  CodeGenOpts<"LegacyPassManager">, DefaultFalse,
  PosFlag<SetTrue, [], "Use the legacy pass manager in LLVM">,
  NegFlag<SetFalse, [], "Use the new pass manager in LLVM">,
  BothFlags<[CC1Option]>>;
```

大多数这样的标记，`-cc1`前端只在该标记和默认的关键路径不对应时，才接受该flag。Clang驱动负责处理这些flag：全部接受，或者将和默认值不同的flag才转发，或者在flag和默认值一致时丢弃之。

`BoolOption`的第一个参数用于构建标记的完整名字的前缀。存在标记命名为`flegacy-pass-manager`，不存在标记命名为`fno-legacy-pass-manager`。`BoolOption`隐含添加`-`前缀。使用`BoolOption`指示使用`f`前缀和`Group<f_Group>`也是可以的。`PosFlag`和`NegFlag`类保存了相关的boolean值、传递给`Flag`类的数组和帮助文本。可选的`BothFlags`类也保存了一个`Flag`数组，这些`Flag`在存在标记和不存在标记中通用；以及通用的帮助文本的后缀。

## 字符串

关键路径的默认值是指定的字符串，或者是空串。



---------------------    

[原文](https://releases.llvm.org/15.0.0/tools/clang/docs/InternalsManual.html#the-frontend-library)
