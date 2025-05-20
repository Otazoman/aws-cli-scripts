# タスク定義作成方法  

タスク定義の作成には以下のコマンドを実行する 

```
REGION=ap-northeast-1
TASKDEF_JSON=file://task-def1.json
aws ecs register-task-definition --no-cli-pager --cli-input-json --region $REGION $TASKDEF_JSON
```


タスク定義の登録解除および削除は以下のコマンドを実行する。(リビジョンは一度作成するとそのままとなってしまうので注意)  

```
ACCOUNTID=YOURACCOUNTID
aws ecs list-task-definitions

TASK_DEFINITION_ARN="arn:aws:ecs:ap-northeast-1:$ACCOUNTID:task-definition/YOURTASKNAME:REVISION"
TASK_DEFINITION_NAME=$(echo "$TASK_DEFINITION_ARN" | awk -F'/' '{print $2}' | cut -d':' -f1)
TASK_DEFINITION_REVISION=$(echo "$TASK_DEFINITION_ARN" | awk -F'/' '{print $2}' | cut -d':' -f2)
aws ecs deregister-task-definition --task-definition $TASK_DEFINITION_NAME:$TASK_DEFINITION_REVISION --region $REGION --no-cli-pager
aws ecs delete-task-definitions --task-definitions $TASK_DEFINITION_NAME:$TASK_DEFINITION_REVISION --region $REGION --no-cli-pager

```
