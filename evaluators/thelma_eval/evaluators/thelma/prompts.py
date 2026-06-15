"""THELMA prompt templates from paper Appendix B."""

CLAIM_EXTRACT_PROMPT = """You are a claim extractor and your job is to extract claims from snippets of text.
You always follow the below guidelines:

<guidelines>
- You only respond with a list of stand-alone claims.
- The list is always inside an <output></output> tags.
- The extracted claims contain only one piece of stand-alone information such that each claim can be verified independently.
- The extracted claims should be independently verifiable but do not need to be true.
- The extracted claims should be stand-alone facts.
- The extracted claims are independent so there is very little overlap between them.
- The list of extracted claims should contain all information from the input.
- Each extracted claim should not be decomposable into multiple claims.
- Generate as many claims as possible.
</guidelines>

Please extract claims from the following text:
<input>
Text: {input}
</input>"""

QUERY_DECOMPOSE_PROMPT = """You are a question decomposer. You will follow following guidelines.

<guidelines>
- You only respond with a list of questions.
- The list is always inside of <output></output> tags.
- You should resolve any ambiguous pronouns in the input text.
- Each extracted question contain only one question.
- Each extracted question is one short question.
- All the extracted questions are from the input questions received.
</guidelines>

Please extract questions from the following text:
<input>
Text: {input}
</input>"""

ESSENTIALITY_PROMPT = """You are an editor. Your task is to identify if given fact contains essential information to answer a query.

Evaluation Criteria: Relevance Score captures whether the information in the fact is essential to answer the specific query asked. This dimension assesses if the response provides relevant details and does not have any irrelevant details.

Instructions:
<instructions>
- Read the query carefully to thoroughly understand the user's query. Identify the key points that are being asked about.
- Analyze the response to ensure it is essential to answer the query.
- Check if response is providing details about same entity or event asked in query.
- Check if the response provides any extraneous details which are not needed to answer the query.
- Provide the response in <output></output> tags.
- Respond only with a value in the scale provided below. No explanations.
</instructions>

Scale:
<scale>
Extraneous - The response is not required to answer the core intent of the query.
Essential - The response is essential to answer the query.
</scale>

Please rate the essentiality of the fact to answer the query:
<input>
Question: {query}
Response: {response}
</input>"""

GROUNDEDNESS_PROMPT = """You are a fact checker. You will be given a claim and a knowledge base.
You will then answer with a 0 or 1 indicating if the claim is not supported or supported by the knowledge base.

<scale>
- 0: The claim is not supported by the knowledge base.
- 1: The claim is definitely supported by the knowledge base.
</scale>

You always adhere to the following guidelines:
<guidelines>
- The output is always between <output> and </output>.
- Only the score is returned. Explanations are forbidden.
</guidelines>

Is the claim supported by the knowledge base?
<input>
<knowledge source> {source} </knowledge source>
<claim>
{claim}
</claim>
</input>"""

COVERAGE_PROMPT = """You are an evaluator. Determine if the following question is answered by the given text.
Respond with 1 if the question is answered, 0 if not.

<guidelines>
- The output is always between <output> and </output>.
- Only the score is returned. No explanations.
</guidelines>

<input>
Question: {question}
Text: {text}
</input>"""
