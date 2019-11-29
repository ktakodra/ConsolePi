#!/usr/bin/env python3

import json
import logging
import logging.handlers
import time
from time import sleep
import socket

import requests
from dlipower import PowerSwitch
from requests.auth import HTTPDigestAuth

DLI_TIMEOUT = 5
SEQUENCE_DELAY = 1
DEBUG = False
TIMING = False

class Dli_Logger:

    def __init__(self, debug=DEBUG):
        self.debug = debug
        self.log = self.set_log()

    def set_log(self):
        log = logging.getLogger(__name__)
        log.setLevel(logging.INFO if not self.debug else logging.DEBUG)
        handler = logging.handlers.SysLogHandler(address='/dev/log')
        handler.setLevel(logging.INFO if not self.debug else logging.DEBUG)
        formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s')
        handler.setFormatter(formatter)
        log.addHandler(handler)
        return log

class DLI:

    def __init__(self, fqdn, username='admin', password='admin', use_https=False, timeout=DLI_TIMEOUT, log=Dli_Logger().log):
        self.timeout = timeout
        self.log = log
        self.scheme = 'http://' if not use_https else 'https://'
        self.reachable, self.ip = self.check_reachable(fqdn, 443 if self.scheme.split(':')[0] == 'https' else 80)
        self.fqdn = fqdn
        self.base_url = self.scheme + str(self.ip)
        self.outlet_url = self.base_url + '/restapi/relay/outlets/'
        self.username = username
        self.passwword = password
        self.rest = None
        if self.reachable:
            self.dli = self.get_session(username, password)
            self.outlets = self.get_dli_outlets()
        else:
            self.dli = self.outlets = {}
        self.pretty = {
            True: 'ON',
            False: 'OFF'
        }
        if TIMING:
            self.hit = 0 ### TIMING
            self._hit = 0 ### TIMING


    def __len__(self):
        """
        :return: Number of outlets
        """
        return len(self.outlets)

    def __repr__(self):
        """
        display the representation
        """
        if not self.outlets:
            return "Digital Loggers Web Powerswitch " \
                   "{} (UNCONNECTED)".format(self.fqdn)
        output = 'DLIPowerSwitch at {}\n' \
                 'Outlet\t{:<15}\tState\n'.format(self.fqdn, 'Name')
        for port in self.outlets:
            # if 'name' in self.outlets[port] and 'state' in self.outlets[port]:
                output += '{}\t{:<15}\t{}\n'.format(port, self.outlets[port]['name'],
                            self.pretty[self.outlets[port]['state']])
        return output

    def __getitem__(self, index):
        if TIMING:
            self._hit += 1
            print('[__getitem__] hit {} processing port {}'.format(self._hit, index))
        outlets = self.get_dli_outlets() # self.outlets # if self.hit == 1 else self.get_dli_outlets()
        if outlets:
            if isinstance(index, slice):
                ret_val = {}
                for o in outlets:
                    if o >= index.start and o <= index.stop:
                        # ret_val[o] = outlets[o]
                        ret_val[o] = {'state': self.state(o), 'name': outlets[o]['name']}
            elif isinstance(index, list):
                ret_val = {}
                for o in index:
                    # ret_val[o] = outlets[o]
                    ret_val[o] = {'state': self.state(o), 'name': outlets[o]['name']}
            else:
                ret_val = {index: {'state': self.state(index), 'name': outlets[index]['name']}}
        else:
            ret_val = outlets
        if TIMING:
            print('\t{}'.format(ret_val))

        return ret_val
    
    def check_reachable(self, host, port, timeout=2):
    # if url is passed check dns first otherwise dns resolution failure causes longer delay
    # determine if host is resolvable
        try:
            s = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)
            _ip = s[0][4][0]
        except (socket.gaierror, socket.timeout, TimeoutError) as e:
            self.log.error('[DLI] {} is not reachable\n{}'.format(host, e))
            _ip = None
            return False, _ip

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        try:
            sock.connect((_ip, port))
            reachable = True
        except (socket.error, TimeoutError):
            reachable = False
        sock.close()

        return reachable, _ip

    def get_session(self, username, password, fqdn=None):
        '''Get or Renew a session with the dli from requests module.'''
        log = self.log
        fqdn = self.fqdn if fqdn is None else fqdn

        headers = {'Accept': 'application/json', 'Connection': 'keep-alive'}
        f_url = self.base_url + '/restapi/relay/version/'
        if TIMING:
            start = time.time() # TIMING
        _session = requests.session()
        _session.auth = HTTPDigestAuth(username, password)
        _session.headers = headers
        r = _session.get(f_url, headers=headers)
        if TIMING:
            print('[TIMING] check api ({}): return: {}, {}'.format(fqdn, r.status_code, time.time() - start)) # TIMING
        if r.headers['Content-Type'] != 'application/json':     # determine if old screen-scrape method is required for older dli units
            log.info("[DLI] Using webui scraping method for {}, it doesn't appear to support the new rest API".format(fqdn)) # TODO log
            self.rest = False
            switch = PowerSwitch(hostname=self.ip, userid=username, password=password, timeout=self.timeout)
            return switch
        else:   # web power switch pro - use rest API
            log.info("[DLI] Using rest API method for {}".format(fqdn)) # TODO log
            self.rest = True
            return _session
        
    def rename(self, port, new_name):
        """Rename the outlet.

        :param port: The outlet to rename (dli outlet numbering starting with 1)
        :param new_name: New name for the outlet
        :returns: True for success, False for Fail
        """
        log = self.log
        if TIMING:
            start = time.time() # TIMING
        if self.rest:
            headers = {'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'}
            data = json.dumps(new_name)
            r = self.dli.put('{}{}/name/'.format(self.outlet_url, port - 1), data=data, headers=headers)
            if r.status_code != 204:
                log.warning('[DLI] {} returned error response to rename request {},{},{}'.format(self.fqdn, r.status_code, r.content, r.reason)) # TODO log
            ret = True if r.status_code == 204 else False
        else:
            ret = self.dli.set_outlet_name(outlet=port, name=new_name)
        if TIMING:
            print('[TIMING] {} rename {}: {}'.format(self.fqdn, port, time.time() - start)) # TIMING
        if ret:
            self.outlets[port]['name'] = self.name(port)
            return self.outlets[port]['name'] == new_name
        else:
            return ret

    def get_dli_outlets(self):
        '''Get Outlet details from dli.

        Uses self.dli session from __init__ 
        returns: dict of outlets
        {
            port:int {
                'name': name:str,
                'state': state:bool, (True = On)
                }
        }
        '''
        log = self.log
        if TIMING:
            self.hit += 1
            print('[GET OUTLETS] hit {}'.format(self.hit))
            start = time.time() # TIMING
        outlet_dict = {}
        if self.rest:
            # New dli API takes about 5 seconds to retrieve the outlet data
            timeout = self.timeout + 3 if self.timeout < 6 else self.timeout
            try:
                r = self.dli.get(self.outlet_url, timeout=timeout)
                outlet_list = json.loads(r.content.decode('UTF-8'))
            except (socket.error, TimeoutError):
                self.reachable = False
                self.dli = self.outlets = {}
            idx = 1
            if self.reachable:
                for outlet in outlet_list:
                    # for _ in ["critical", "cycle_delay", "locked", "physical_state", "transient_state"]:
                    #     # nul = outlet.pop(_)
                    #     del outlet[_]
                    outlet_dict[idx] = {'name': outlet['name'], 'state': outlet['state']}
                    idx += 1
        else:
            self.reachable = self.check_reachable(self.fqdn, port=443 if 'https' in self.scheme else 80)[0]
            if self.reachable:
                retry = 0
                while retry <= 2:
                    outlet_list = self.dli.statuslist()
                    if outlet_list: # can be None if dli suffers transient issue
                        for outlet in outlet_list:
                            outlet_dict[outlet[0]] = {'name': outlet[1], 'state': True if outlet[2].upper() == 'ON' else False}
                        break
                    retry += 1
                if not outlet_list:
                    log.error('[DLI GET OUTLETS] dli @ {} reachable, but failed to fetch statuslist (outlet_list)'.format(self.fqdn))
                    self.reachable = False
                    self.dli = self.outlets = {}
            else:
                self.reachable = False
                self.dli = self.outlets = {}
        if TIMING:
            print('[TIMING] {} get_dli_outlets: {}'.format(self.fqdn, time.time() - start)) # TIMING
        return outlet_dict # if len(outlet_dict) > 0 else None

    def operate_port(self, port, toState=None, func='toggle'):
        '''Toggle or cycle Power on all or a specified port.

        parameters:
            port: The Interface to toggle
        '''
        log = self.log
        bool_state = {
            'ON': True,
            'OFF': False
        }
        # --// SUB Toggle or Cycle Power On Specified Port \\--
        def toggle_sub(port, toState):
            '''Toggle or Cycle Power on Outlet.'''
            port_idx = port - 1
            base_url = self.outlet_url + str(port_idx)
            f_url = base_url + '/state/' if func == 'toggle' else '{}/{}/'.format(base_url, func.lower())
            # use rest API available on newer web power switches (i.e. web power switch Pro)
            if self.rest:
                if func == 'toggle':
                    req = getattr(self.dli, 'put') 
                    headers = {'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'}
                    data = json.dumps(toState)
                elif func == 'cycle':
                    req = getattr(self.dli, 'post')
                    headers = {'X-Requested-With': 'XMLHttpRequest'}
                    data = None
                r = req(f_url, data=data, headers=headers)
                if len(r.text) == 0:
                    return r.status_code
                else:
                    return r.json() # rest api returns content false with status 200 if state was off when cycle was issued
            else:   # dlipower.PowerSwitch - screen scrape library
                if func == 'toggle':
                    if toState:
                        r = self.dli.on(port)
                    else:
                        r = self.dli.off(port)

                    if not r: # dlipower.PowerSwitch returns False if operation Success
                        return toState
                    else:
                        return '{} Port {} dlipower library gave an unexpected response: {}'.format(
                            self.fqdn, port, r)
                elif func == 'cycle':
                    if curState:
                        if TIMING:
                            start = time.time() # TIMING
                        r = self.dli.cycle(port)
                        if TIMING:
                            print('[TIMING] {} cycle {}: {}'.format(self.fqdn, port, time.time() - start)) # TIMING
                        return not r
                    else: 
                        return False # a False response from cycle indicates port was already off nothing occured
            # -- END TOGGLE SUB --

        # --// Determine what the new powered state should be \\--
        if toState is not None and isinstance(toState, str):        # TODO should be able to remove, refactored to bool
            if toState.lower() in ['on', 'off']:
                toState = True if toState.lower() == 'on' else False
            else:
                log.error('[DLI] invalid toState Passed to function')

            # --// Validate port passed into method \\--
            if isinstance(port, int) and port <= len(self.outlets):
                pass # valid
            elif isinstance(port, str) and port.lower() == 'all':
                pass # valid
            elif isinstance(port, list):
                for p in port:
                    if not p in self.outlets.keys():
                        log.error('[DLI] port {} provided in port list: {} is not valid')
            else:
                log.error('[DLI] Invalid Value provided for port {}'.format(port))

        elif toState is None:   # No toState provided set toState based on opposite of curState
            if isinstance(port, int):
                curState = self.state(port)
                toState = not curState
            elif isinstance(port, str):
                if port == 'all':
                    if func == 'toggle':
                        raise Exception('all specified without desired end state')

        # --// perform the func on the port(s) \\--#
        # -- single port passed into method --
        if TIMING:
            start = time.time() # TIMING
        if isinstance(port, int):
            ret_val = toggle_sub(port, toState)
            if TIMING:
                print('[TIMING {}] {} {} {}: {}'.format('rest' if self.rest else 'webui', self.fqdn, func, port, time.time() - start)) # TIMING
        # -- keyword 'all' passed into method --
        elif (isinstance(port, str) and port == 'all'):
            if func.lower() == 'toggle':
                toState = 'ON' if toState else 'OFF'
                if self.rest:
                    url=self.base_url + '/outlet?a=' + toState
                    ret_val = self.verify_session(url)
                else:
                    r = self.dli.geturl(url='outlet?a=' + toState)
                    ret_val = 200 if r is not None else 400
            elif func.lower() == 'cycle':
                if self.rest:
                    url = '{}/outlet?a=CCL'.format(self.base_url)
                    ret_val = self.verify_session(url)
                else:
                    r = self.dli.geturl(url='outlet?a=CCL')
                    ret_val = 200 if r is not None else 400
                return ret_val
            else:
                print('Invalid value for func argument') # TODO logging exception
            if TIMING:
                print('[TIMING] {} {} {}: {}'.format(self.fqdn, func, port, time.time() - start)) # TIMING
        # -- something else (should be list of slice) passed in --
        else:
            ret_val = []
            for p in port:
                if TIMING:
                    start = time.time() # TIMING
                r = toggle_sub(p, toState)
                if TIMING:
                    print('[TIMING {}] {} {} {}: {}'.format('rest' if self.rest else 'webui', self.fqdn, func, p, time.time() - start)) # TIMING
                if isinstance(r, tuple):
                    ret_val.append(r[0])
                else:
                    ret_val.append(r)
                sleep(SEQUENCE_DELAY)
            log.debug('DLI {}] Return values for ports: {} = {}'.format(func, port, ret_val))
            ret_val = list(dict.fromkeys(ret_val)) # get rid of all duplicates
            if len(ret_val) == 1:
                ret_val = ret_val[0]
            else:
                for status_code in ret_val:
                    if status_code > 204:
                        ret_val = status_code

        if isinstance(ret_val, bool):
            return ret_val
        elif ret_val <= 204:    # toggle power
            return toState if isinstance(toState, bool) else bool_state[toState]
        else:
            return 'An Error occured {}'.format(ret_val)

    def verify_session(self, url):
        '''perform http get operation against dli if the response indicates the session is expired get a new session and retry.
        
        Used by new rest capable dli web power switches, for all operations, given no API method is available for all operations.
        '''
        log = self.log
        retry = 0
        while retry < 3:
            # -- attempt to perform the action --
            r = self.dli.get(url)
            # -- check to see if session expired --
            if r.content.decode('UTF-8').split('URL=')[1].split('"')[0] != '/index.htm':
                log.debug('[DLI VRFY SESSION] Session appears expired for {}. Renewing... {}'.format(self.fqdn, ' Retry ' + str(retry) if retry > 0 else ''))
                self.dli = self.get_session(self.dli.auth.username, self.dli.auth.password, fqdn=self.fqdn)
            else:
                ret_val = r.status_code
                if ret_val != 200:
                    log.error('[DLI VRFY SESSION] call to ' + url + 'returned ' + str(ret_val))
                    print('[DLI VRFY SESSION] call to ' + url + 'returned ' + str(ret_val))
                break
            retry += 1

        if r.content.decode('UTF-8').split('URL=')[1].split('"')[0] != '/index.htm':
            log.warn('[DLI VRFY SESSION] Unable to Renew Session for {}'.format(self.fqdn))
            ret_val = 400

        return ret_val


    def get_port_info(self, port, fetch='state'):
        '''
        returns Bool Representing current port state ~ True = ON
        '''
        log = self.log
        if self.outlets is not None:
            if isinstance(port, int) and port <= len(self.outlets):
                if self.rest:
                    _url = self.outlet_url + str(port - 1) + '/{}/'.format(fetch)
                    try:
                        r = self.dli.get(_url, timeout=self.timeout)
                        if r.status_code == 200:
                            _return = r.json() # TODO - error exception catch
                        else:
                            log.error('[DLI] Bad status code {} retunred while checking current {} of port'.format(r.status_code, fetch))
                            _return = '[DLI] Bad status code {} retunred while checking current {} of port'.format(r.status_code, fetch)
                    except (socket.error, TimeoutError):
                        self.reachable = False
                        log.error('[DLI] {} appears to be unreachable now'.format(_url))
                        _return = 'Error: [DLI] {} appears to be unreachable now'.format(_url)
                else:
                    if fetch == 'state':
                        _return = self.dli.status(port)
                        if _return.upper() == 'ON':
                            _return = True
                        elif _return.upper() == 'OFF':
                            _return = False
                        else:
                            log.error('[DLI] {} returned invalid state "{}" for port {}'.format(self.fqdn, _return, port))
                    elif fetch == 'name':
                        _return = self.dli.get_outlet_name(port)
            else:
                _return = 'error: invalid port type {}'.format(type(port))
        else:
            _return = 'Error: UNREACHABLE'
        if fetch == 'state' and _return in [True, False]:
            self.outlets[port]['state'] = _return   # ensure outlet dict has current state
        elif fetch == 'name':
            self.outlets[port]['name'] = _return
            
        return _return
       
    def toggle(self, port, toState=None):
        return self.operate_port(port, toState=toState)

    def cycle(self, port):
        return self.operate_port(port, toState=None, func='cycle')

    def state(self, port):
        return self.get_port_info(port)

    def name(self, port):
        return self.get_port_info(port, fetch='name')

    def close(self):
        '''
        Be a good citizen and close the session with the dli
        This will help prevent session exaustion on the dli
        This should be called after operations are complete
        '''
        log = self.log
        if self.rest:
            r = self.dli.get(url='{}/logout'.format(self.base_url))
            self.dli.close()
        else:
            r = self.dli.session.get(self.dli.base_url + '/logout')
            self.dli.session.close()
        if r.status_code != 200:
            log.warning('[DLI] Attempt to logout of {0} returned error \n\t{1} {2}: {3}\n\tHeaders: {4}'.format(
                self.fqdn, r.status_code, r.reason, r.text, r.headers))

if __name__ == '__main__':
    pass
    fqdn = 'labpower1.kabrew.com'
    # start = time.time() # TIMING
    l1 = DLI(fqdn, username='admin', password='hpIMC!!!')
    # print('[TIMING] get l1 session time: {}'.format(time.time() - start)) # TIMING
    # # print(l1.s.auth)
    # # print(l1.outlets)
    # # print('l1-toggle', l1.toggle('all', 'off'))
    # # range = slice(3, 7)
    print(l1[5])
    # # print('l1-cycle', l1.cycle(8))
    # print('l1-toggle', l1.toggle([1, 5], 'off'))
    # print('l1-cycle-all', l1.cycle('all'))
    # print('l1-rename', l1.rename(1, 'Digi'))
    l1.close()
    # # print(l1.s.auth)
    fqdn = 'labpower2.kabrew.com'
    l2 = DLI(fqdn, username='admin', password='hpIMC!!!')
    print(l2[5])
    # # print(l2.switch.session.auth)
    # # print(l2.outlets)
    # print('l2-toggle', l2.toggle([1, 4]))
    # print('l2-cycle', l2.cycle('all'))
    # print('l2-rename', l2.rename(7, 'VACANT'))
    l2.close()
    # print(l2.switch.session.auth)
