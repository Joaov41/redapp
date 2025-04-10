# redapp
A Reddit Universal app ( Apple silicon Macs and Ipads) that works with a free personal Reddit API key, featuring comment summarization and Q&A about the comments. 

Inspired by the incredible work of the team at https://lo.cafe, particularly their fantastic app OpenArtemis,  set out to enhance this concept of an app that uses Reddit’s free personal API, aiming to add the functionality of comments summarization.

Just type the name of the subreddit (without the r/), select the nuber of posts to show ( maximum 100) and the if New, Hot, or Top and press load

![CleanShot 2025-04-10 at 18 52 57@2x](https://github.com/user-attachments/assets/e3a2c145-3e8e-4c6b-9a1c-4bd19b22ec5a)



This is the main view of the posts.Pressing the image will open same on a separate view, swiping right to left open that post on the browser if you like to comment on it, swiping left ro right will whow more of the truncated text of the post
![CleanShot 2025-04-10 at 18 53 21@2x](https://github.com/user-attachments/assets/90127103-680b-4659-ad8a-1882a5431331)


Pressing the title of each posts will take you to the comments
![image](https://github.com/user-attachments/assets/8193c0b6-00cc-4dc2-a291-87de530c7521)
![image](https://github.com/user-attachments/assets/dcbc293d-c1c5-457d-a0a7-33faa97c3adf)

There you can find the Summarize comments button which will provide a compreensive summarization of the comments. The Summarize is verbose, it was designed this for my personal preference, if you wish for something short just go directly to the ask question part and enter a simple prompt like "give me a short summary of the comments"
Either pressing the summarize button first or going direcly to ther ask question, the ask function allows to engage in q&a about the comments of that post.
The copy comments button, copies the comments to clipboard appeding a summarization prompt, for those cases in which you prefer to use another llm for the summariatio, that way just pasted on that other llm because the cvomments have been extracted with a summary prompt.
![image](https://github.com/user-attachments/assets/600ad73d-f209-4fa0-8f48-674de1f14cd4)

Since i wanted to maintain the comments visible while having the summary visiable at the same time, it was necessary to do some compromises on a small screen.
Drag this down to extend the summary/ask view to the preferable size
![CleanShot 2025-01-10 at 12 50 35@2x](https://github.com/user-attachments/assets/10106124-b0cc-4440-bef3-2dd4b561a14a)

![image](https://github.com/user-attachments/assets/90a82c7e-c7d4-4d32-be4f-fd96291ed3c2)


INSTRUCTIONS:
Download xcode from Apple

Open the file  redapp2.xcodeproj
Install package Kingfisher

Get a gemeni api key from Google ai studio
Get a free reddit API credentials 


As most people do now own a paid Apple developer account, it is best to export to an IPA file and sideload through one of the available tools for that.

UPDATE: I have added the ipa file notorized by Apple

Fixed a bug where on posts with a large number of comments, the app would become slow or unresponsive. 
Fixed a bug where on posts with a large number of comments, the app would hit a limite and would only consider up to 200 comments. Now it can handle all the comments , even if it reaches hundreds.
