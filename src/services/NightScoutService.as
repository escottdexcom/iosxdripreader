package services
{
	import com.distriqt.extension.dialog.Dialog;
	import com.distriqt.extension.dialog.DialogView;
	import com.distriqt.extension.dialog.builders.AlertBuilder;
	import com.distriqt.extension.dialog.objects.DialogAction;
	import com.distriqt.extension.networkinfo.NetworkInfo;
	import com.distriqt.extension.networkinfo.events.NetworkInfoEvent;
	import com.hurlant.crypto.hash.SHA1;
	import com.hurlant.util.Hex;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.net.URLLoader;
	import flash.net.URLRequestMethod;
	import flash.net.URLVariables;
	
	import mx.collections.ArrayCollection;
	
	import spark.formatters.DateTimeFormatter;
	
	import Utilities.Trace;
	import Utilities.UniqueId;
	
	import databaseclasses.BgReading;
	import databaseclasses.BlueToothDevice;
	import databaseclasses.Calibration;
	import databaseclasses.CommonSettings;
	import databaseclasses.LocalSettings;
	
	import events.BackGroundFetchServiceEvent;
	import events.CalibrationServiceEvent;
	import events.NightScoutServiceEvent;
	import events.SettingsServiceEvent;
	import events.TransmitterServiceEvent;
	
	import model.ModelLocator;
	
	public class NightScoutService extends EventDispatcher
	{
		[ResourceBundle("nightscoutservice")]
		
		private static var _instance:NightScoutService = new NightScoutService();
		
		public static function get instance():NightScoutService
		{
			return _instance;
		}
		
		
		private static var initialStart:Boolean = true;
		private static var loader:URLLoader;
		private static var _nightScoutEventsUrl:String = "";
		private static var testUniqueId:String;
		private static var hash:SHA1 = new SHA1();
		
		private static var _syncRunning:Boolean = false;
		private static var lastSyncrunningChangeDate:Number = (new Date()).valueOf();
		private static const maxMinutesToKeepSyncRunningTrue:int = 1;
		
		private static function get syncRunning():Boolean
		{
			if (!_syncRunning)
				return false;
			
			if ((new Date()).valueOf() - lastSyncrunningChangeDate > maxMinutesToKeepSyncRunningTrue * 60 * 1000) {
				lastSyncrunningChangeDate = (new Date()).valueOf();
				_syncRunning = false;
				return false;
			}
			return true;
		}
		
		private static function set syncRunning(value:Boolean):void
		{
			_syncRunning = value;
			lastSyncrunningChangeDate = (new Date()).valueOf();
		}
		
		
		private static var _hashedAPISecret:String = "";
		
		/**
		 * should be a function that takes a BackGroundFetchServiceEvent as parameter and no return value 
		 */
		private static var functionToCallAtUpOrDownloadSuccess:Function = null;
		/**
		 * should be a function that takes a BackGroundFetchServiceEvent as parameter and no return value 
		 */
		private static var functionToCallAtUpOrDownloadFailure:Function = null;
		
		public function NightScoutService()
		{
			if (_instance != null) {
				throw new Error("NightScoutService class constructor can not be used");	
			}
		}
		
		public static function init():void {
			if (!initialStart)
				return;
			else
				initialStart = false;
			
			_hashedAPISecret = Hex.fromArray(hash.hash(Hex.toArray(Hex.fromString(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_API_SECRET)))));
			_nightScoutEventsUrl = "https://" + CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) + "/api/v1/entries";
			
			CommonSettings.instance.addEventListener(SettingsServiceEvent.SETTING_CHANGED, settingChanged);
			TransmitterService.instance.addEventListener(TransmitterServiceEvent.BGREADING_EVENT, bgreadingEventReceived);
			CalibrationService.instance.addEventListener(CalibrationServiceEvent.INITIAL_CALIBRATION_EVENT, initialCalibrationReceived);
			NetworkInfo.networkInfo.addEventListener(NetworkInfoEvent.CHANGE, networkChanged);
			BackGroundFetchService.instance.addEventListener(BackGroundFetchServiceEvent.LOAD_REQUEST_ERROR, defaultErrorFunction);
			BackGroundFetchService.instance.addEventListener(BackGroundFetchServiceEvent.LOAD_REQUEST_RESULT, defaultSuccessFunction);
			BackGroundFetchService.instance.addEventListener(BackGroundFetchServiceEvent.PERFORM_FETCH, performFetch);

			if (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) != CommonSettings.DEFAULT_SITE_NAME
				&&
				CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_API_SECRET) != CommonSettings.DEFAULT_API_SECRET
				&&
				CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_URL_AND_API_SECRET_TESTED) == "false"
			) {
				testNightScoutUrlAndSecret();
			} else if (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) != CommonSettings.DEFAULT_SITE_NAME
				&&
				CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_API_SECRET) != CommonSettings.DEFAULT_API_SECRET
				&&
				CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_URL_AND_API_SECRET_TESTED) == "true"
			) {
				sync();
			}
			
			function initialCalibrationReceived(event:CalibrationServiceEvent):void {
				sync();
			}
			
			function performFetch(event:BackGroundFetchServiceEvent):void {
				myTrace("sync : performfetch");
				sync();
			}
			
			function bgreadingEventReceived(event:TransmitterServiceEvent):void {
				calculateTag();
				//BackgroundFetch.storeBloodGlucoseValue(BgReading.lastNoSensor().calculatedValue);
				
				if (!ModelLocator.isInForeground) {
					myTrace("bgreadingEventReceived started but not in foreground, not starting sync");
				} else {
					sync();
				}
			}
			
			function networkChanged(event:NetworkInfoEvent):void {
				if (NetworkInfo.networkInfo.isReachable()) {
					if (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) != CommonSettings.DEFAULT_SITE_NAME
						&&
						CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_API_SECRET) != CommonSettings.DEFAULT_API_SECRET
						&&
						CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_URL_AND_API_SECRET_TESTED) == "false"
					) {
						testNightScoutUrlAndSecret();
					} else if (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) != CommonSettings.DEFAULT_SITE_NAME
						&&
						CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_API_SECRET) != CommonSettings.DEFAULT_API_SECRET
						&&
						CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_URL_AND_API_SECRET_TESTED) == "true"
					) {
						sync();
					}
				} 
			}
			
			function settingChanged(event:SettingsServiceEvent):void {
				if (event.data == CommonSettings.COMMON_SETTING_API_SECRET) {
					LocalSettings.setLocalSetting(LocalSettings.LOCAL_SETTING_WARNING_THAT_NIGHTSCOUT_URL_AND_SECRET_IS_NOT_OK_ALREADY_GIVEN, "false");
					_hashedAPISecret = Hex.fromArray(hash.hash(Hex.toArray(Hex.fromString(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_API_SECRET)))));
					CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_URL_AND_API_SECRET_TESTED,"false");
				} else if (event.data == CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) {
					LocalSettings.setLocalSetting(LocalSettings.LOCAL_SETTING_WARNING_THAT_NIGHTSCOUT_URL_AND_SECRET_IS_NOT_OK_ALREADY_GIVEN, "false");
					_nightScoutEventsUrl = "https://" + CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) + "/api/v1/entries";
					CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_URL_AND_API_SECRET_TESTED,"false");
				}
				
				if (event.data == CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME || event.data == CommonSettings.COMMON_SETTING_API_SECRET) {
					if (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) != CommonSettings.DEFAULT_SITE_NAME
						&&
						CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_API_SECRET) != CommonSettings.DEFAULT_API_SECRET
						&& 
						!syncRunning) {
						testNightScoutUrlAndSecret();
					}
				}
			}
		}
		
		private static function calculateTag():void {
			var latestReadings:ArrayCollection = BgReading.latestBySize(1);
			
			if (latestReadings.length > 0) { 
				var minute:Number = (new Date((latestReadings[0]  as BgReading).timestamp)).minutesUTC;
				var tagNumber:int = minute % 5;
				//example if bgreading is generated in minute 24, tagnumber = 4
				switch (tagNumber) { 
					case 0:
						if (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG) != "TWO") {
							LocalSettings.setLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG, "TWO");
						}
						break;
					case 1:
						if (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG) != "THREE") {
							LocalSettings.setLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG, "THREE");
						}
						break;
					case 2:
						if (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG) != "FOUR") {
							LocalSettings.setLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG, "FOUR");
						}
						break;
					case 3:
						if (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG) != "FIVE") {
							LocalSettings.setLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG, "FIVE");
						}
						break;
					case 4:
						if (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG) != "ONE") {
							LocalSettings.setLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG, "ONE");
						}
						break;
				}
				
			}
		}

		private static function testNightScoutUrlAndSecret():void {
			//test if network is available
			if (NetworkInfo.networkInfo.isReachable()) {
				var testEvent:Object = new Object();
				testUniqueId = UniqueId.createEventId();
				testEvent["_id"] = testUniqueId;
				testEvent["eventType"] = "Exercise";
				testEvent["duration"] = 20;
				testEvent["notes"] = "to test nightscout url";
				var nightScoutTreatmentsUrl:String = "https://" + CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) + "/api/v1/treatments";
				myTrace("call_to_nightscout_to_verify_url_and_secret");
				createAndLoadURLRequest(nightScoutTreatmentsUrl, URLRequestMethod.PUT,null,JSON.stringify(testEvent), nightScoutUrlTestSuccess, nightScoutUrlTestError);
			} else {
				myTrace("call_to_nightscout_to_verify_url_and_secret_can_not_be_made");
			}
		}
		
		private static function nightScoutUrlTestSuccess(event:BackGroundFetchServiceEvent):void {
			myTrace("nightScoutUrlTestSuccess with information =  " + event.data.information as String);
			functionToCallAtUpOrDownloadSuccess = null;
			functionToCallAtUpOrDownloadFailure = null;
			
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_URL_AND_API_SECRET_TESTED,"true");
			myTrace("nightscout_test_result_ok");
			var nightScoutTreatmentsUrl:String = "https://" + CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) + "/api/v1/treatments";
			createAndLoadURLRequest(nightScoutTreatmentsUrl + "/" + testUniqueId, URLRequestMethod.DELETE, null, null,sync, null);

			myTrace(ModelLocator.resourceManagerInstance.getString("nightscoutservice","nightscout_test_result_ok"));
			
			if (ModelLocator.isInForeground) {
				var alert:DialogView = Dialog.service.create(
					new AlertBuilder()
					.setTitle(ModelLocator.resourceManagerInstance.getString("nightscoutservice","nightscout_title"))
					.setMessage(ModelLocator.resourceManagerInstance.getString("nightscoutservice","nightscout_test_result_ok"))
					.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
					.build()
				);
				DialogService.addDialog(alert, 60);
			}
		}
		
		private static function nightScoutUrlTestError(event:BackGroundFetchServiceEvent):void {
			myTrace("nightScoutUrlTestError with information =  " + event.data.information as String);
			functionToCallAtUpOrDownloadSuccess = null;
			functionToCallAtUpOrDownloadFailure = null;

			if (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WARNING_THAT_NIGHTSCOUT_URL_AND_SECRET_IS_NOT_OK_ALREADY_GIVEN) == "false" && ModelLocator.isInForeground) {
				var errorMessage:String = ModelLocator.resourceManagerInstance.getString("nightscoutservice","nightscout_test_result_nok");
				errorMessage += "\n" + event.data.information;
				
				if ((event.data.information as String).indexOf("Cannot PUT /api/v1/treatments") > -1) {
					errorMessage += "\n" + ModelLocator.resourceManagerInstance.getString("nightscoutservice","care_portal_should_be_enabled");
				}
				
				myTrace(errorMessage);
				
				var alert:DialogView = Dialog.service.create(
					new AlertBuilder()
					.setTitle(ModelLocator.resourceManagerInstance.getString("nightscoutservice","nightscout_title"))
					.setMessage(errorMessage)
					.addOption("Ok", DialogAction.STYLE_POSITIVE, 0)
					.build()
				);
				DialogService.addDialog(alert, 60);
				myTrace("nightscout_test_result_nok");
				LocalSettings.setLocalSetting(LocalSettings.LOCAL_SETTING_WARNING_THAT_NIGHTSCOUT_URL_AND_SECRET_IS_NOT_OK_ALREADY_GIVEN, "true");
			}
		}
		
		public static function sync(event:Event = null):void {
			//myTrace("LOCAL_SETTING_DEVICE_TOKEN_ID = " + LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_DEVICE_TOKEN_ID));
			//myTrace("LOCAL_SETTING_SUBSCRIBED_TO_PUSH_NOTIFICATIONS = " + LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_SUBSCRIBED_TO_PUSH_NOTIFICATIONS));
			//myTrace("LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG = " + LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG));
			//myTrace("LOCAL_SETTING_ACTUAL_QBLOX_SUBSCRIPTION_TAG = " + LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_ACTUAL_QBLOX_SUBSCRIPTION_TAG));
			if (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_DEVICE_TOKEN_ID) != ""
				&&
				ModelLocator.isInForeground//registerpushnotification is using loadeer, which only works when app is in foreground
				&&
				(LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_SUBSCRIBED_TO_PUSH_NOTIFICATIONS) == "false"
				||
				(LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG)
					!=
				LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_ACTUAL_QBLOX_SUBSCRIPTION_TAG)))
			) {
				myTrace("sync, url and secret tested, device token not empty and not subscribed, so registering now for push notifications");
				BackGroundFetchService.registerPushNotification(LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_WISHED_QBLOX_SUBSCRIPTION_TAG));
			}
				
			
			if (syncRunning) {
				myTrace("NightScoutService.as sync : sync running already, return");
				return;
			}
			
			functionToCallAtUpOrDownloadSuccess = null;
			functionToCallAtUpOrDownloadFailure = null;
			
			var starttime:Number  = (new Date()).valueOf();
			if (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME) == CommonSettings.DEFAULT_SITE_NAME
				||
				CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_API_SECRET) == CommonSettings.DEFAULT_API_SECRET
				||
				CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_URL_AND_API_SECRET_TESTED) ==  "false") {
				BackGroundFetchService.callCompletionHandler(BackGroundFetchService.NO_DATA);
				return;
			}
			
			if (Calibration.allForSensor().length < 2) {
				BackGroundFetchService.callCompletionHandler(BackGroundFetchService.NO_DATA);
				return;
			}
			
			myTrace("setting syncRunning = true");
			syncRunning = true;
			
			var listOfReadingsAsArray:Array = [];
			var lastSyncTimeStamp:Number = new Number(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_NIGHTSCOUT_SYNC_TIMESTAMP));
			var formatter:DateTimeFormatter = new DateTimeFormatter();
			formatter.dateTimePattern = "yyyy-MM-dd'T'HH:mm:ss.SSSZ";
			formatter.setStyle("locale", "en_US");
			formatter.useUTC = false;
			
			var cntr:int = ModelLocator.bgReadings.length - 1;
			var arrayCntr:int = 0;
			
			while (cntr > -1) {
				var bgReading:BgReading = ModelLocator.bgReadings.getItemAt(cntr) as BgReading;
				if (bgReading.timestamp > lastSyncTimeStamp) {
					if (bgReading.calculatedValue != 0) {
						var newReading:Object = new Object();
						newReading["device"] = BlueToothDevice.name;
						newReading["date"] = bgReading.timestamp;
						newReading["dateString"] = formatter.format(bgReading.timestamp);
						newReading["sgv"] = Math.round(bgReading.calculatedValue);
						newReading["direction"] = bgReading.slopeName();
						newReading["type"] = "sgv";
						newReading["filtered"] = bgReading.ageAdjustedFiltered() * 1000;
						newReading["unfiltered"] = bgReading.usedRaw() * 1000;
						newReading["rssi"] = 100;
						newReading["noise"] = bgReading.noiseValue();
						newReading["xDrip_filtered_calculated_value"] = bgReading.filteredCalculatedValue;
						newReading["xDrip_raw"] = bgReading.rawData;
						newReading["xDrip_filtered"] = bgReading.filteredData;
						newReading["xDrip_calculated_value"] = bgReading.calculatedValue;
						newReading["xDrip_age_adjusted_raw_value"] = bgReading.ageAdjustedRawValue;
						newReading["xDrip_calculated_current_slope"] = BgReading.currentSlope();
						newReading["xDrip_hide_slope"] = bgReading.hideSlope;
						newReading["sysTime"] = formatter.format(bgReading.timestamp);
						newReading["_id"] = bgReading.uniqueId;
						listOfReadingsAsArray[arrayCntr] = newReading;
					}
				} else {
					break;
				}
				cntr--;
				arrayCntr++;
			}			
			
			var endtime:Number  = (new Date()).valueOf();
			
			myTrace("sync , time taken to go through bgreadings = " + ((endtime - starttime)/1000) + " seconds");
			if (listOfReadingsAsArray.length > 0) {
				myTrace("listOfReadingsAsArray.length > 0");
				var logString:String = ".. not filled in ..";
				/*for (var cntr2:int = 0; cntr2 < listOfReadingsAsArray.length; cntr2++) {
				logString += " " + listOfReadingsAsArray[cntr2]["_id"] + ",";
				}*/
				myTrace("uploading_events_with_id" + logString);
				createAndLoadURLRequest(_nightScoutEventsUrl, URLRequestMethod.POST, null, JSON.stringify(listOfReadingsAsArray), nightScoutUploadSuccess, nightScoutUploadFailed);
			} else {
				myTrace("setting syncRunning = false");
				BackGroundFetchService.callCompletionHandler(BackGroundFetchService.NO_DATA);
				syncRunning = false;
			}
		}
		
		private static function nightScoutUploadSuccess(event:Event):void {
			myTrace("in nightScoutUploadSuccess");
			BackGroundFetchService.callCompletionHandler(BackGroundFetchService.NEW_DATA);
			
			myTrace("upload_to_nightscout_successfull");
			CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_NIGHTSCOUT_SYNC_TIMESTAMP, (new Date()).valueOf().toString());
			syncFinished(true);
		}
		
		private static function nightScoutUploadFailed(event:BackGroundFetchServiceEvent):void {
			myTrace("in nightScoutUploadFailed");
			BackGroundFetchService.callCompletionHandler(BackGroundFetchService.FETCH_FAILED);
			
			var errorMessage:String;
			if (event.data) {
				if (event.data.information)
					errorMessage = event.data.information;
			} else {
				errorMessage = "";
			}
			
			myTrace("upload_to_nightscout_unsuccessfull" + errorMessage);
			syncFinished(false);
		}
		
		private static function defaultErrorFunction(event:BackGroundFetchServiceEvent):void {
			myTrace("in defaultErrorFunction");
			if(functionToCallAtUpOrDownloadFailure != null) {
				myTrace("in defaultErrorFunction functionToCallAtUpOrDownloadFailure != null");
				functionToCallAtUpOrDownloadFailure(event);
			}
			else {
				myTrace("in defaultErrorFunction functionToCallAtUpOrDownloadFailure = null");
				BackGroundFetchService.callCompletionHandler(BackGroundFetchService.FETCH_FAILED);
			}
			
			functionToCallAtUpOrDownloadSuccess = null;
			functionToCallAtUpOrDownloadFailure = null;
		}
		private static function defaultSuccessFunction(event:BackGroundFetchServiceEvent):void {
			myTrace("in defaultSuccessFunction");
			if(functionToCallAtUpOrDownloadSuccess != null) {
				myTrace("in defaultSuccessFunction functionToCallAtUpOrDownloadSuccess != null");
				functionToCallAtUpOrDownloadSuccess(event);
			}
			else {
				myTrace("in defaultSuccessFunction functionToCallAtUpOrDownloadSuccess = null");
				BackGroundFetchService.callCompletionHandler(BackGroundFetchService.NEW_DATA);
			}
			
			functionToCallAtUpOrDownloadSuccess = null;
			functionToCallAtUpOrDownloadFailure = null;
		}
		
		/**
		 * creates URL request and loads it<br>
		 */
		private static function createAndLoadURLRequest(url:String, requestMethod:String, urlVariables:URLVariables, data:String, successFunction:Function, errorFunction:Function):void {
			if (errorFunction != null) {
				functionToCallAtUpOrDownloadFailure = errorFunction;
			} else
				functionToCallAtUpOrDownloadFailure = null;
			if (successFunction != null) {
				functionToCallAtUpOrDownloadSuccess = successFunction;
			} else {
				functionToCallAtUpOrDownloadSuccess = null;
			}
			BackGroundFetchService.createAndLoadUrlRequest(url, requestMethod ? requestMethod:URLRequestMethod.GET, urlVariables, data, "application/json", "api-secret", _hashedAPISecret);
		}
		
		private static function myTrace(log:String):void {
			Trace.myTrace("NightScoutService.as", log);
		}
		
		private static function syncFinished(result:Boolean):void {
			myTrace("syncfinished");
			myTrace("setting syncRunning = false");
			syncRunning = false;
		}
		
	}
}