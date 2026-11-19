// Prints the Node version the runner actually used for a `using: node20` action.
const major = Number(process.versions.node.split('.')[0]);
console.log(`node20 probe ran on Node ${process.version}`);
// The images ship only Node 24, so that is what the runner must have used.
if (major !== 24) process.exit(1);
