rcheevos v12.5.0 (https://github.com/RetroAchievements/rcheevos), MIT.
RAIntegration, 3DS encrypted hashing and the test/validator dirs are left out.
One local patch, marked "Dena.emu patch" in src/rc_client.c: a game unloaded
while its mastery event is pending no longer dereferences a NULL game.
