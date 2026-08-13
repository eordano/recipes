const { describe } = require("@example-npm/util");
console.log(describe(Number(process.argv[2] ?? 7)));
