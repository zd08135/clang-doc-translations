
# 函数和语句块

函数的定义/声明产生式如下：  
```
$funcdecl -> $storage $typeref $name "(" $params ")" ";"
$def_func -> $storage $typeref $name "(" $params ")" $block
```

llvm中，提供了一个用于描述函数的llvm::Value子类：llvm::Function

llvm::Function如果携带了BasicBlock的话，那么这些BasicBlock就是这个函数的代码，  
也可以理解成一般意义上的“定义”

