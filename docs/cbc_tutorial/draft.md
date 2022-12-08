
章节划分

1. 前言
2. 环境搭建（容器化+自动脚本）
3. 基本运行
4. lex + parse
5. 类型
6. 函数
7. CFG
8. 类型转换
9. 指针，数组，结构体

--------------------------------------

背景  

教程比较完善的资料，工程化内容较多，且产出内容可以实际使用的->青木峰郎《自制编译器》。  
研究CBC编译器。 
CBC只能用于x86，2022年的现在，纯x86环境很难构建，且编译出来的程序也没法运行。  
目前市面的教程大部分都是x86的，在2022年，基本只能作为教学用途了。  

目标：  
用更modern的llvm作为编译后端支持，可以构建出可实际运行在amd64环境下的应用/库。  
选择CBC，是因为CBC已经筛选了C中比较核心的内容，给了一套产生式语义规范。  

-----------------------------------------------------

许可证

https://github.com/aamine/cbc/blob/master/README


- 代码二次发布时，需要包含此许可。 
- 编译二进制二次发布时，需要包含次许可和其他需要发布的文档。 
- 如果基于这些代码做了自己的产品，再未经正式许可的情况下，不能添加原作者/贡献者的名字。 

以上我们都没涉及，所以只保留链接。
