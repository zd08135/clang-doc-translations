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




---------------------    

[原文](https://releases.llvm.org/15.0.0/tools/clang/docs/InternalsManual.html#the-frontend-library)
