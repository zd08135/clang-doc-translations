
$DOCS_PATH="cbc_tutorial"

git checkout main

cp docs/${DOCS_PATH}/.gitbook.yaml .
cp docs/${DOCS_PATH}/README.md .
cp docs/${DOCS_PATH}/SUMMARY.md .

$BRANCH_NAME="release-cbc-tutorial"

git branch -D ${BRANCH_NAME}
git checkout -B ${BRANCH_NAME}
git commit -a -m "rebuild ${BRANCH_NAME} branch"
git push --set-upstream origin ${BRANCH_NAME} -f