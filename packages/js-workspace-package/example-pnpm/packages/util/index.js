const isOdd = require("is-odd");
module.exports.describe = (n) => `${n} is ${isOdd(n) ? "odd" : "even"}`;
