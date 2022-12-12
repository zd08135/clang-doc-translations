# LLVM基础

## 架构基础

（网上的类似教程很多，不赘述）  


## 编程基础

我们假设读者已经看过官方教程kaleidoscope的代码。  
基本的LLVMContext, LLVMIRBuilder, LLVMModule这几个模块基本知道怎么用了。  
（请参考本书首页提供的Kaleidoscope的教程的链接）  

这里只是简单提一下

1. LLVMContext是一个核心数据结构，贯穿整个编译过程始终。  
   在所有的编译过程中，只需要使用一个全局唯一对象即可。  

2. 一个LLVMModule对象，对应一个编译单元，IR生成和目标文件生成等，生成的具体的数据必须落在某个指定的Module上。  


3. LLVMIRBuilder，这个主要的作用是提供用户输入到IR指令数据的转换，本身不持有任何信息。  

其他的部分，会在用到的章节中提出。  

