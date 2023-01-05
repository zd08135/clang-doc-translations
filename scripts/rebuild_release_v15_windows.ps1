
$DOCS_PATH="llvm-docs-15.0.0"

git checkout main

cp docs/${DOCS_PATH}/.gitbook.yaml .
cp docs/${DOCS_PATH}/README.md .
cp docs/${DOCS_PATH}/SUMMARY.md .

$BRANCH_NAME="release-cbc-v15"

git branch -D ${BRANCH_NAME}
git checkout -B ${BRANCH_NAME}
git commit -a -m "rebuild ${BRANCH_NAME} branch"
git push --set-upstream origin ${BRANCH_NAME} -f