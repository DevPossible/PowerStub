// echoargs.exe - test fixture for the parsing matrix (tests/ParsingMatrix.tests.ps1).
//
// Prints exactly what the process received, as one line of JSON:
//   {"Count":2,"Args":["hello world","-v"],"RawTail":"\"hello world\" -v"}
//
// Args    - the arguments as the runtime parsed them
// RawTail - the raw command line after the program name, which shows the quoting the
//           caller produced. Two calls can parse to the same Args yet differ here.
//
// Compiled at test time with the csc.exe that ships with Windows, so keep this to
// C# 5 syntax (no string interpolation, no expression-bodied members).

using System;
using System.Text;

public static class EchoArgs
{
    public static int Main(string[] args)
    {
        StringBuilder json = new StringBuilder();
        json.Append("{\"Count\":").Append(args.Length).Append(",\"Args\":[");
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) { json.Append(','); }
            AppendJsonString(json, args[i]);
        }
        json.Append("],\"RawTail\":");
        AppendJsonString(json, GetRawTail(Environment.CommandLine));
        json.Append('}');

        Console.OutputEncoding = new UTF8Encoding(false);
        Console.Out.WriteLine(json.ToString());
        return 0;
    }

    // Skips the program name (quoted or not) at the start of the raw command line.
    private static string GetRawTail(string commandLine)
    {
        int i = 0;
        if (commandLine.Length > 0 && commandLine[0] == '"')
        {
            i = commandLine.IndexOf('"', 1);
            i = i < 0 ? commandLine.Length : i + 1;
        }
        else
        {
            while (i < commandLine.Length && commandLine[i] != ' ' && commandLine[i] != '\t') { i++; }
        }
        while (i < commandLine.Length && (commandLine[i] == ' ' || commandLine[i] == '\t')) { i++; }
        return commandLine.Substring(i);
    }

    private static void AppendJsonString(StringBuilder json, string value)
    {
        json.Append('"');
        foreach (char c in value)
        {
            switch (c)
            {
                case '"': json.Append("\\\""); break;
                case '\\': json.Append("\\\\"); break;
                case '\n': json.Append("\\n"); break;
                case '\r': json.Append("\\r"); break;
                case '\t': json.Append("\\t"); break;
                default:
                    if (c < 0x20 || c > 0x7e)
                    {
                        json.Append("\\u").Append(((int)c).ToString("x4"));
                    }
                    else
                    {
                        json.Append(c);
                    }
                    break;
            }
        }
        json.Append('"');
    }
}
