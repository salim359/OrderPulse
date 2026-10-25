/** Structured pipeline stage logs for CloudWatch (Lambda workers). */

export function pipelineLog(
  stage: string,
  message: string,
  fields: Record<string, unknown> = {},
): void {
  console.log(
    JSON.stringify({
      pipeline: true,
      stage,
      msg: message,
      ...fields,
    }),
  );
}
