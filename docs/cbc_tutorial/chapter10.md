## 指针类型

因为上述opaque ptr的缘故，llvm中的指针没有类型，在llvm一层，所有的指针类型都返回同一个值。 
我们必须在前端记录指针和指向的值的类型。
  
PointerType有一个成员
  
## 针对typedef的处理

typedef语句的格式如下：  
```
"typedef" ${type} ${identifier} ";"

比如
typedef unsigned long FILE;
```

上述示例中，typedef将FILE声明成为了一个类型。那么下面的语句就应该可以编译。  
并且在实际生成IR时，去掉FILE这个声明，直接用unsigned long代替之。  
```
extern FILE* fopen(char* path, char* mode);
```

而在解析到这个extern语句时，就必须要知道FILE是一个类型，而不是一个标识符。
这就需要在解析到上面的typedef时，除了生成typedef的AST之外，  
还要记录FILE->unsigned long这样一个类型别名的映射，在解析到下面的extern时，将FILE当做类型解析，解析时查询类型别名的映射，才可以正常编译该语句。  