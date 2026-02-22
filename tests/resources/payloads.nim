import std/json

const
  ALPHABETIC* = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  ALPHANUMERIC* = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  ALPHANUMERIC_SPECIAL* =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;':\\\",./<>?`~"
  EMOJI* =
    "😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙"
  CODE* = "def main():\n\tprint('Hello, world!')"
  QUERY* = """
    SELECT
      u.id,
      u.name,
      u.email,
      u.created_at,
      u.updated_at,
      (
        SELECT
          COUNT(*)
        FROM
          posts p
        WHERE
          p.user_id = u.id
      ) AS post_count
    FROM
      users u
    WHERE
      u.id = 1
    """
  TEXT_SMALL* = "Lorem ipsum dolor sit amet, consectetur adipiscing elit."
  TEXT_LARGE* = """
    Lorem ipsum dolor sit amet, consectetur adipiscing elit. Cras gravida vulputate semper. Proin 
    eleifend varius cursus. Morbi lacinia posuere quam sit amet pretium. Sed non metus fermentum, 
    venenatis nisl id, vestibulum eros. Quisque non lorem sit amet lectus faucibus elementum eu 
    sit amet odio. Mauris tortor justo, malesuada quis volutpat vitae, tristique at nisl. Proin 
    eleifend eu arcu ac sodales. In efficitur ipsum urna, ut viverra turpis sodales ut. Phasellus 
    nec tortor eu urna suscipit euismod eget vel ligula. Phasellus vestibulum sollicitudin tellus, 
    ac sodales tellus tempor id. Curabitur sed congue velit. 
    """

proc getSampleJsonDictionary*(): JsonNode =
  %*{
    "shapes": [{"type": "circle", "radius": 10}, {"type": "square", "side": 10}],
    "colours": ["red", "green", "blue"],
  }

proc getSampleJsonList*(): JsonNode =
  %*[{"type": "cat", "name": "Salem"}, {"type": "dog", "name": "Oberon"}]

proc getByteSequence*(bytesNumber: uint64): seq[byte] =
  result = newSeq[byte](bytesNumber)
  for i in 0 ..< bytesNumber:
    result[i] = cast[byte](i mod 256)
  return result
