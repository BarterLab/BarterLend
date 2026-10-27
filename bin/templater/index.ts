const fs = require("fs");
const path = require("path");

type Syntax =
	| { type: "text"; value: string }
	| { type: "for"; variable: string; values: string[]; body: Syntax[] };

function parse(lines: string[]): Syntax[] {
	const syntax: Syntax[] = [];
	let index = 0;

	function go(): Syntax[] {
		const syntax: Syntax[] = [];

		const line = lines[index++];
		const forMatch = line.match(/^\/\/= for\s+(\w+)\s+in\s+\[([^\]]+)\]$/);
		if (forMatch) {
			const variable = forMatch[1];
			const values = forMatch[2].split(",").map(v => v.trim()).filter(Boolean);
			const body: Syntax[] = [];
			while (index < lines.length && !lines[index].match(/^\/\/= end for\s*$/)) {
				body.push(...go());
			}

			index++;
			syntax.push({ type: "for", variable, values, body });
		} else {
			syntax.push({ type: "text", value: line });
		}

		return syntax;
	}

	while (index < lines.length) {
		syntax.push(...go());
	}

	return syntax;
}

function render(syntax: Syntax[], scope: Record<string, string> = {}): string {
	let result: string[] = [];

	for (const node of syntax) {
		if (node.type === "text") {
			let value = node.value;
			for (const [key, val] of Object.entries(scope)) {
				value = value.replace(new RegExp(`\\$\\{${key}(?::(CamelCase))?\\}`, "g"), (_, transform) => {
					if (transform === "CamelCase") {
						return camelCase(val);
					} else {
						return val;
					}
				});
			}
			result.push(value);
		} else if (node.type === "for") {
			for (const val of node.values) {
				result.push(render(node.body, { ...scope, [node.variable]: val }));
			}
		}
	}

	return result.join("\n");

}

function main() {
	const input = process.argv[2];
	const output = process.argv[3];

	if (!input) {
		console.error(`usage: node ${path.basename(__filename)} input [output]`);
		process.exit(1);
	}

	const source: string = fs.readFileSync(input, "utf8");
	const syntax = parse(source.split("\n"));
	const result = render(syntax);

	if (output) {
		fs.writeFileSync(output, result);
	} else {
		process.stdout.write(result);
	}
}

function camelCase(value: string): string {
	return value.charAt(0).toUpperCase() + value.slice(1);
}


main();
