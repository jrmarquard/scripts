import { ListObjectsV2Command, S3Client, _Object } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

import { GetObjectCommand } from "@aws-sdk/client-s3";

const isObjectAFile = (object: _Object) => {
  return object.Key.split("/").pop() !== "";
};

type scriptParam = {
  Bucket: string;
  Prefix: string;
  outputType?: "logJson" | "logPretty";
};

const TWELVE_HOURS = 43200;

const script = async ({ Bucket, Prefix, outputType }: scriptParam) => {
  const s3Client = new S3Client({ region: "ap-southeast-2" });

  const listObjs = new ListObjectsV2Command({
    Bucket,
    Prefix,
  });

  const objects = await s3Client.send(listObjs);
  const _promises = objects.Contents.filter(isObjectAFile).map(async (c) => {
    return {
      fileName: c.Key.split("/").pop(),
      signedUrl: await getSignedUrl(
        s3Client,
        new GetObjectCommand({
          Bucket,
          Key: c.Key,
        }),
        { expiresIn: TWELVE_HOURS }
      ),
    };
  });
  const links = await Promise.all(_promises);

  switch (outputType) {
    case "logJson": {
      console.log(JSON.stringify(links, null, 4));
      break;
    }
    case "logPretty": {
      const str = links
        .map((l) => `${l.fileName}\n${l.signedUrl}\n`)
        .join("\n");
      console.log(str);
      break;
    }
    default: {
      console.log(JSON.stringify(links, null, 4));
    }
  }
};

const cleanArgs = process.argv
  .slice(2)
  .filter((arg) => arg.match(/^--.*=.*$/))
  .reduce((args: { [x: string]: string }, arg) => {
    const groups = arg.match(/^--(.*)=(.*)$/);
    args[groups[1]] = groups[2];
    return args;
  }, {});

script(cleanArgs as scriptParam);
