import re

with open("yuedu app/Models/Models.swift", 'r') as f:
    code = f.read()

code = re.sub(
    r'if let coverImageOptional = session\?\.publication\.cover\(\), let coverImage = coverImageOptional \{',
    r'if let coverResult = await session?.publication.cover(), case .success(let optionalImage) = coverResult, let coverImage = optionalImage {',
    code
)

with open("yuedu app/Models/Models.swift", 'w') as f:
    f.write(code)
