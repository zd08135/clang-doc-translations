
# 变量

现在，可以定义基本类型的变量了。  


变量分为局部变量和全局变量。  
我们先考虑局部变量的实现。

# 局部变量

如果用clang编译C语言代码，生成ir时，会看到有很多的alloca指令：
```
Function Attrs: noinline nounwind optnone uwtable
define dso_local i32 @my_function(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  ...
```
> https://releases.llvm.org/15.0.0/docs/LangRef.html#alloca-instruction

alloca的作用是在当前执行函数的栈帧上分配空间，这些空间在函数执行结束返回给调用者时自动释放。  
可以用alloca分配的空间来作为局部变量。  

alloca的作用十分强大，除了基本类型之外，数组/指针/结构体等都可以用alloca指令分配。  
这里先看针对基本类型的局部变量的分配。  

创建alloca的接口如下：
```
AllocaInst *CreateAlloca(Type *Ty, Value *ArraySize = nullptr,
                           const Twine &Name = "");
```

CreateAlloca实际上是分配了一个空间，返回指向该空间的指针，对应的值的类型为PointerType

- Ty: 变量类型
- ArraySize：只能传一个IntegerType的Value值，这个参数没啥用。实际上ArrayType本身就有size，传指定值的ArrayType就可以正确分配。  
- Name：这里有一个误解就是这里必须传变量的名字。实际上这里传的值只是一个指示性的作用。变量和名字的关联是由前端自己解决的。如果看clang的ir，这里就没有名字。不过为了方便调试，我们在调用时，会传入变量的名字。  


