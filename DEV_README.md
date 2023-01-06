
# 本书的开发流程

本书内容在github上编辑，并通过github->gitbook同步的方式，将内容同步到gitbook上发布。

同步过程中，gitbook需要依赖.gitbook.yaml中的内容来生成对应的章节目录。  

我们采用的方式是：

1. 每一本书，单独开一个目录，并指定独立的如下文件，这些文件不同的书各自维持一份。  
- .gitbook.yaml
- SUMMARY.md

2. 每一套书，指定一个release分支。  
   在该分支中，根目录中的上述文件由该书对应目录的上述文件替代。  

3. 所有的书本内容，都集中到同一个main分支中，方便总览。  

4. 如果某本书的内容有更新，将该分支基于最新的main分支重建，并复制.gitbook.yaml文件。  
（在scripts目录下，新增该书对应release分支的构建脚本，该脚本windows和linux版本都要）

注：gitbook处理SUMMARY.md的目录有些问题，似乎是在处理SUMMARY时，  
   会以该文件所在路径作为root查询文件，而不是.gitbook.yaml指定的root查询。

